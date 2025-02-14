# cython: language_level=3
# cython: boundscheck=False
# cython: wraparound=False
## cython: profile=True

import cython
from libc.stdlib cimport calloc, free
from libc.math cimport sqrt
import numpy as np
cimport numpy as np

cdef extern from "math.h":
    float expf(float x)
    float log1pf(float x)
    float fabsf(float x)
    float fmaxf(float x, float y)


ALPHABET = 'ACGT'
LARGE_VAL = 1e30


##############################
###### Helper functions ######
##############################

"""
The overhead from (even inline) helper function calls mean they are
not used, but left here for reference.
"""

cdef inline size_t nstate_to_nbase(size_t nstate):
    """Convert number of flip-flop states to number of bases and check for
    valid states number.
    """
    cdef float nbase_f = sqrt(0.25 + (0.5 * nstate)) - 0.5
    cdef size_t nbase = <size_t>nbase_f
    return nbase

cdef inline size_t trans_lookup(size_t from_b, size_t to_b, size_t nbase):
    if to_b < nbase:
        return to_b * (nbase + nbase) + from_b
    return nbase * (nbase + nbase) + from_b

cdef inline float logaddexp(float x, float y):
    return fmaxf(x, y) + log1pf(expf(-fabsf(x - y)))

cdef inline void log_row_normalise_inplace(
        float * mat, size_t ncol, size_t nrow):
    cdef size_t col, row, offset
    cdef float row_logsum
    for col in range(ncol):
        offset = col * nrow
        row_logsum = mat[offset]
        for row in range(1, nrow):
            row_logsum = logaddexp(row_logsum, mat[offset + row])

        for row in range(0, nrow):
            mat[offset + row] -= row_logsum

    return

cdef inline void get_stay_step(
        size_t * seq, size_t nseq, size_t nbase,
        size_t * stay_indices, size_t * step_indices):
    cdef size_t * flop_mask_states = <size_t *> calloc(nseq, sizeof(size_t))
    stay_indices[0] = trans_lookup(seq[0], seq[0], nbase)
    flop_mask_states[0] = seq[0]
    cdef size_t seq_pos, prev_fm_state, curr_fm_state
    for seq_pos in range(1, nseq):
        prev_fm_state = flop_mask_states[seq_pos - 1]
        if seq[seq_pos] == prev_fm_state:
            curr_fm_state = seq[seq_pos] + nbase
        else:
            curr_fm_state = seq[seq_pos]
        flop_mask_states[seq_pos] = curr_fm_state
        stay_indices[seq_pos] = trans_lookup(
            curr_fm_state, curr_fm_state, nbase)
        step_indices[seq_pos - 1] = trans_lookup(
            prev_fm_state, curr_fm_state, nbase)
    free(flop_mask_states)
    return


################################
###### Decoding functions ######
################################

cdef inline void decode_forward_step(
        float * curr_logprob, size_t nbase,
        float * prev_fwd, float * curr_fwd, size_t * tb):
    cdef size_t nff_state = nbase + nbase

    # ib -- fl[i]p to base states
    cdef size_t ib, ob, offset_to_state, from_state
    cdef float score
    for ib in range(nbase):
        offset_to_state = ib * nff_state
        # from 0 base state
        curr_fwd[ib] = curr_logprob[offset_to_state + 0] + prev_fwd[0]
        tb[ib] = 0
        for from_state in range(1, nff_state):
            # rest of from base states (either flip or flop)
            score = (curr_logprob[offset_to_state + from_state] +
                     prev_fwd[from_state])
            if score > curr_fwd[ib]:
                curr_fwd[ib] = score
                tb[ib] = from_state

    cdef size_t offset_to_flop = nff_state * nbase
    # ob -- fl[o]p to base state
    for ob in range(nbase, nff_state):
        # stay state
        curr_fwd[ob] = prev_fwd[ob] + curr_logprob[offset_to_flop + ob]
        tb[ob] = ob
        # move from flip to flop state
        from_state = ob - nbase
        score = (curr_logprob[offset_to_flop + from_state] +
                 prev_fwd[from_state])
        if score > curr_fwd[ob]:
            curr_fwd[ob] = score
            tb[ob] = from_state

    return


cdef float flipflop_decode_trans(
        np.ndarray[np.float32_t, ndim=2] tpost, size_t nblk, size_t nbase,
        np.ndarray[np.uintp_t, ndim=1] path,
        np.ndarray[np.float32_t, ndim=1] qpath):
    cdef size_t nff_state = nbase + nbase
    cdef size_t ntrans_state = nff_state * (nbase + 1)

    cdef np.ndarray[np.uintp_t, ndim=2] tb = np.empty(
        (nblk, nff_state), dtype=np.uintp)

    cdef float * curr = <float *> calloc(nff_state, sizeof(float))
    cdef float * prev = <float *> calloc(nff_state, sizeof(float))
    cdef float * tmp
    cdef size_t idx
    for idx in range(nff_state):
        curr[idx] = 0

    # Forwards Viterbi pass
    cdef size_t blk
    for blk in range(nblk):
        # swap curr and prev
        tmp = prev
        prev = curr
        curr = tmp
        decode_forward_step(&tpost[blk,0], nbase, prev, curr, &tb[blk,0])

    cdef size_t max_idx = 0
    cdef float score = curr[0]
    for idx in range(1, nff_state):
        if curr[idx] > score:
            score = curr[idx]
            max_idx = 0

    free(prev)
    free(curr)

    # Traceback
    cdef size_t trans_idx
    path[nblk] = max_idx
    for blk in range(nblk, 0, -1):
        path[blk - 1] = tb[blk - 1, path[blk]]
        trans_idx = (path[blk] * (nbase + nbase) + path[blk - 1]
                     if path[blk] < nbase else
                     nbase * (nbase + nbase) + path[blk - 1])
        qpath[blk] = tpost[blk - 1, trans_idx]
    qpath[0] = np.nan

    return score


cdef void decode_forward(
        np.ndarray[np.float32_t, ndim=2] logprob, size_t nbase, size_t nblk,
        np.ndarray[np.float32_t, ndim=2] fwd):
    cdef size_t nff_state = nbase + nbase
    cdef size_t ntrans_state = nff_state * (nbase + 1)

    cdef size_t idx
    for idx in range(nff_state):
        fwd[0, idx] = 0

    cdef size_t * tmp_tb = <size_t *> calloc(nff_state, sizeof(size_t))
    cdef size_t blk
    for blk in range(nblk):
        decode_forward_step(&logprob[blk,0], nbase, &fwd[blk,0],
                            &fwd[blk + 1,0], tmp_tb)

    free(tmp_tb)

    return


cdef void flipflop_trans_post(
    np.ndarray[np.float32_t, ndim=2] logprob, size_t nbase, size_t nblk,
    np.ndarray[np.float32_t, ndim=2] tpost):
    cdef size_t nff_state = nbase + nbase
    cdef size_t ntrans_state = nff_state * (nbase + 1)

    cdef np.ndarray[np.float32_t, ndim=2] fwd = np.empty(
        (nblk + 1, nff_state), dtype=np.float32)

    decode_forward(logprob, nbase, nblk, fwd)

    cdef float * curr = <float *> calloc(nff_state, sizeof(float))
    cdef float * prev = <float *> calloc(nff_state, sizeof(float))
    cdef float * tmp
    cdef size_t idx
    for idx in range(nff_state):
        prev[idx] = -LARGE_VAL

    # Backwards pass
    cdef size_t blk, ib, ob, st, from_base
    cdef float score
    for blk in range(nblk, 0, -1):
        # swap curr and prev
        tmp = prev
        prev = curr
        curr = tmp

        for ib in range(nbase):
            # End up in flip state
            for st in range(nff_state):
                tpost[blk - 1, ib * nff_state + st] = (
                    fwd[blk - 1, st] + prev[ib] +
                    logprob[blk - 1, ib * nff_state + st])
        for ob in range(nbase, nff_state):
            # End up in flop state
            ib = ob - nbase
            tpost[blk - 1, nff_state * nbase + ob] = (
                fwd[blk - 1, ob] + prev[ob] +
                logprob[blk - 1, nff_state * nbase + ob])
            tpost[blk - 1, nff_state * nbase + ib] = (
                fwd[blk - 1, ib] + prev[ob] +
                logprob[blk - 1, nff_state * nbase + ib])

        # Update backwards vector
        # ob -- fl[o]p to base state
        for ob in range(nbase, nff_state):
            from_base = ob - nbase
            # Stay in flop state
            curr[ob] = logprob[blk - 1, nff_state * nbase + ob] + prev[ob]
            # Move from flip to flop state
            curr[from_base] = logprob[
                blk - 1, nff_state * nbase + from_base] + prev[ob]
        # ib -- fl[i]p to base states
        for ib in range(nbase):
            for from_base in range(nff_state):
                # rest of from base states (either flip or flop)
                score = (
                    logprob[blk - 1, ib * nff_state + from_base] +
                    prev[ib])
                if score > curr[from_base]:
                    curr[from_base] = score

    free(curr)
    free(prev)

    #log_row_normalise_inplace(&tpost[0,0], nblk, ntrans_state)
    cdef float row_logsum, tpost_val
    for blk in range(nblk):
        row_logsum = tpost[blk, 0]
        for st in range(1, ntrans_state):
            tpost_val = tpost[blk, st]
            row_logsum = fmaxf(row_logsum, tpost_val) + log1pf(
                expf(-fabsf(row_logsum - tpost_val)))
        for st in range(ntrans_state):
            tpost[blk, st] -= row_logsum

    return


##########################################
###### Standard flip-flop functions ######
##########################################

def crf_flipflop_trans_post(np.ndarray[np.float32_t, ndim=2, mode="c"] logprob,
                            log=True):
    """ Get posteriors from transition weights
    """
    cdef size_t nblock, nparam, nbase
    nblock, nparam = logprob.shape[0], logprob.shape[1]
    nbase = nstate_to_nbase(nparam)

    cdef np.ndarray[np.float32_t, ndim=2, mode="c"] tpost = np.zeros_like(
        logprob)
    flipflop_trans_post(logprob, nbase, nblock, tpost)
    if not log:
        # perform exp inplace
        np.exp(tpost, out=tpost)

    return tpost


def crf_flipflop_viterbi(np.ndarray[np.float32_t, ndim=2, mode="c"] tpost,
                         np.ndarray[np.uintp_t, ndim=1, mode="c"] path,
                         np.ndarray[np.float32_t, ndim=1, mode="c"] qpath):
    """ Fast flip-flop Viterbi decoding calling C implementation
    """
    cdef size_t nblock, nparam, nbase
    nblock, nparam = tpost.shape[0], tpost.shape[1]
    nbase = nstate_to_nbase(nparam)

    score = flipflop_decode_trans(tpost, nblock, nbase, path, qpath)

    return score


##############################
###### Sequence scoring ######
##############################

cdef float score_best_path(
        np.ndarray[np.float32_t, ndim=2] tpost, np.ndarray[np.uintp_t] seq,
        size_t tpost_start, size_t tpost_end, size_t nseq, size_t nbase):
    cdef size_t ntrans_state = (nbase + nbase) * (nbase + 1)
    cdef size_t nblk = tpost_end - tpost_start
    cdef size_t window_width = nblk - nseq + 2

    cdef size_t * stay_indices = <size_t *> calloc(nseq, sizeof(size_t))
    cdef size_t * step_indices = <size_t *> calloc(nseq - 1, sizeof(size_t))
    #get_stay_step(seq, nseq, nbase, stay_indices, step_indices)
    cdef size_t * flop_mask_states = <size_t *> calloc(nseq, sizeof(size_t))
    stay_indices[0] = (seq[0] * (nbase + nbase) + seq[0]
                       if seq[0] < nbase else
                       nbase * (nbase + nbase) + seq[0])
    flop_mask_states[0] = seq[0]
    cdef size_t seq_pos, prev_fm_state, curr_fm_state
    for seq_pos in range(1, nseq):
        prev_fm_state = flop_mask_states[seq_pos - 1]
        if seq[seq_pos] == prev_fm_state:
            curr_fm_state = seq[seq_pos] + nbase
        else:
            curr_fm_state = seq[seq_pos]
        flop_mask_states[seq_pos] = curr_fm_state
        stay_indices[seq_pos] = (
            curr_fm_state * (nbase + nbase) + curr_fm_state
            if curr_fm_state < nbase else
            nbase * (nbase + nbase) + curr_fm_state)
        step_indices[seq_pos - 1] = (
            curr_fm_state * (nbase + nbase) + prev_fm_state
            if curr_fm_state < nbase else
            nbase * (nbase + nbase) + prev_fm_state)
    free(flop_mask_states)

    cdef float * curr = <float *> calloc(window_width, sizeof(float))
    cdef float * prev = <float *> calloc(window_width, sizeof(float))
    cdef float * tmp

    cdef size_t win_pos, trans_pos, stay_idx, step_idx
    cdef float stay_score, step_score, wp_score, pos_tpost
    # cumsum over stay in first seq pos to init prev
    prev[0] = 0.0
    stay_idx = stay_indices[0]
    for win_pos in range(1, window_width):
        wp_score = prev[win_pos - 1]
        trans_pos = tpost_start + win_pos - 1
        prev[win_pos] = wp_score + tpost[trans_pos, stay_idx]

    for seq_pos in range(1, nseq):
        wp_score = prev[0]
        stay_idx = stay_indices[seq_pos]
        step_idx = step_indices[seq_pos - 1]
        pos_tpost = tpost[tpost_start + seq_pos - 1, step_idx]
        curr[0] = wp_score + pos_tpost
        for win_pos in range(1, window_width):
            trans_pos = tpost_start + seq_pos + win_pos - 1

            # compute step score
            wp_score = prev[win_pos]
            pos_tpost = tpost[trans_pos, step_idx]
            step_score = wp_score + pos_tpost

            # compute stay score
            wp_score = curr[win_pos - 1]
            pos_tpost = tpost[trans_pos, stay_idx]
            stay_score = wp_score + pos_tpost

            # store best path score
            if step_score > stay_score:
                curr[win_pos] = step_score
            else:
                curr[win_pos] = stay_score
        # swap prev and curr scores
        tmp = prev
        prev = curr
        curr = tmp

    cdef float score = prev[window_width - 1]
    free(stay_indices)
    free(step_indices)
    free(curr)
    free(prev)

    return score


cdef float score_all_paths(
        np.ndarray[np.float32_t, ndim=2] tpost, np.ndarray[np.uintp_t] seq,
        size_t tpost_start, size_t tpost_end, size_t nseq, size_t nbase):
    cdef size_t ntrans_state = (nbase + nbase) * (nbase + 1)
    cdef size_t nblk = tpost_end - tpost_start
    cdef size_t window_width = nblk - nseq + 2

    cdef size_t * stay_indices = <size_t *> calloc(nseq, sizeof(size_t));
    cdef size_t * step_indices = <size_t *> calloc(nseq - 1, sizeof(size_t));
    #get_stay_step(seq, nseq, nbase, stay_indices, step_indices)
    cdef size_t * flop_mask_states = <size_t *> calloc(nseq, sizeof(size_t))
    stay_indices[0] = (seq[0] * (nbase + nbase) + seq[0]
                       if seq[0] < nbase else
                       nbase * (nbase + nbase) + seq[0])
    flop_mask_states[0] = seq[0]
    cdef size_t seq_pos, prev_fm_state, curr_fm_state
    for seq_pos in range(1, nseq):
        prev_fm_state = flop_mask_states[seq_pos - 1]
        if seq[seq_pos] == prev_fm_state:
            curr_fm_state = seq[seq_pos] + nbase
        else:
            curr_fm_state = seq[seq_pos]
        flop_mask_states[seq_pos] = curr_fm_state
        stay_indices[seq_pos] = (
            curr_fm_state * (nbase + nbase) + curr_fm_state
            if curr_fm_state < nbase else
            nbase * (nbase + nbase) + curr_fm_state)
        step_indices[seq_pos - 1] = (
            curr_fm_state * (nbase + nbase) + prev_fm_state
            if curr_fm_state < nbase else
            nbase * (nbase + nbase) + prev_fm_state)
    free(flop_mask_states)

    cdef float * curr = <float *> calloc(window_width, sizeof(float))
    cdef float * prev = <float *> calloc(window_width, sizeof(float))
    cdef float * tmp

    cdef size_t win_pos, trans_pos, stay_idx, step_idx
    cdef float stay_score, step_score, wp_score, pos_tpost
    # cumsum over stay in first seq pos to init prev
    prev[0] = 0.0
    stay_idx = stay_indices[0]
    for win_pos in range(1, window_width):
        wp_score = prev[win_pos - 1]
        trans_pos = tpost_start + win_pos - 1
        prev[win_pos] = wp_score + tpost[trans_pos, stay_idx]

    for seq_pos in range(1, nseq):
        wp_score = prev[0]
        stay_idx = stay_indices[seq_pos]
        step_idx = step_indices[seq_pos - 1]
        pos_tpost = tpost[tpost_start + seq_pos - 1, step_idx]
        curr[0] = wp_score + pos_tpost
        for win_pos in range(1, window_width):
            trans_pos = tpost_start + seq_pos + win_pos - 1

            # compute step score
            wp_score = prev[win_pos]
            pos_tpost = tpost[trans_pos, step_idx]
            step_score = wp_score + pos_tpost

            # compute stay score
            wp_score = curr[win_pos - 1]
            pos_tpost = tpost[trans_pos, stay_idx]
            stay_score = wp_score + pos_tpost

            # store Viterbi all paths score
            curr[win_pos] = fmaxf(stay_score, step_score) + log1pf(
                expf(-fabsf(stay_score - step_score)))
        # swap prev and curr scores
        tmp = prev
        prev = curr
        curr = tmp

    cdef float score = prev[window_width - 1]
    free(stay_indices)
    free(step_indices)
    free(curr)
    free(prev)

    return score


def score_seq(
        np.ndarray[np.float32_t, ndim=2, mode="c"] tpost,
        np.ndarray[np.uintp_t, ndim=1, mode="c"] seq,
        tpost_start, tpost_end, all_paths):
    nseq = seq.shape[0]
    nbase = nstate_to_nbase(tpost.shape[1])
    if all_paths:
        return score_all_paths(tpost, seq, tpost_start, tpost_end, nseq, nbase)
    return score_best_path(tpost, seq, tpost_start, tpost_end, nseq, nbase)


##################################
###### Mod Sequence scoring ######
##################################

cdef float score_best_path_mod(
        np.ndarray[np.float32_t, ndim=2] tpost, np.ndarray[np.uintp_t] seq,
        np.ndarray[np.uintp_t] mod_cats,
        np.ndarray[np.uintp_t] can_mods_offsets, size_t tpost_start,
        size_t tpost_end, size_t nseq, size_t nstate):
    cdef size_t nbase = nstate_to_nbase(nstate - can_mods_offsets[4])
    cdef size_t ntrans_state = (nbase + nbase) * (nbase + 1)
    cdef size_t nblk = tpost_end - tpost_start
    cdef size_t window_width = nblk - nseq + 2

    cdef size_t * stay_indices = <size_t *> calloc(nseq, sizeof(size_t));
    cdef size_t * step_indices = <size_t *> calloc(nseq - 1, sizeof(size_t));
    #get_stay_step(seq, nseq, nbase, stay_indices, step_indices)
    cdef size_t * flop_mask_states = <size_t *> calloc(nseq, sizeof(size_t))
    stay_indices[0] = (seq[0] * (nbase + nbase) + seq[0]
                       if seq[0] < nbase else
                       nbase * (nbase + nbase) + seq[0])
    flop_mask_states[0] = seq[0]
    cdef size_t seq_pos, prev_fm_state, curr_fm_state
    for seq_pos in range(1, nseq):
        prev_fm_state = flop_mask_states[seq_pos - 1]
        if seq[seq_pos] == prev_fm_state:
            curr_fm_state = seq[seq_pos] + nbase
        else:
            curr_fm_state = seq[seq_pos]
        flop_mask_states[seq_pos] = curr_fm_state
        stay_indices[seq_pos] = (
            curr_fm_state * (nbase + nbase) + curr_fm_state
            if curr_fm_state < nbase else
            nbase * (nbase + nbase) + curr_fm_state)
        step_indices[seq_pos - 1] = (
            curr_fm_state * (nbase + nbase) + prev_fm_state
            if curr_fm_state < nbase else
            nbase * (nbase + nbase) + prev_fm_state)
    free(flop_mask_states)

    cdef float * curr = <float *> calloc(window_width, sizeof(float))
    cdef float * prev = <float *> calloc(window_width, sizeof(float))
    cdef float * tmp

    cdef size_t win_pos, trans_pos, stay_idx, step_idx, mod_idx
    cdef float stay_score, step_score, wp_score, pos_tpost, pos_mod_tpost
    # cumsum over stay in first seq pos to init prev
    prev[0] = 0.0
    stay_idx = stay_indices[0]
    for win_pos in range(1, window_width):
        wp_score = prev[win_pos - 1]
        trans_pos = tpost_start + win_pos - 1
        prev[win_pos] = wp_score + tpost[trans_pos, stay_idx]

    for seq_pos in range(1, nseq):
        wp_score = prev[0]
        stay_idx = stay_indices[seq_pos]
        step_idx = step_indices[seq_pos - 1]
        pos_tpost = tpost[tpost_start + seq_pos - 1, step_idx]
        mod_idx = ntrans_state + can_mods_offsets[seq[seq_pos]] + \
                  mod_cats[seq_pos]
        pos_mod_tpost = tpost[tpost_start + seq_pos - 1, mod_idx]
        curr[0] = wp_score + pos_tpost + pos_mod_tpost
        for win_pos in range(1, window_width):
            trans_pos = tpost_start + seq_pos + win_pos - 1

            # compute step score
            wp_score = prev[win_pos]
            pos_tpost = tpost[trans_pos, step_idx]
            pos_mod_tpost = tpost[trans_pos, mod_idx]
            step_score = wp_score + pos_tpost + pos_mod_tpost

            # compute stay score
            wp_score = curr[win_pos - 1]
            pos_tpost = tpost[trans_pos, stay_idx]
            stay_score = wp_score + pos_tpost

            # store best path score
            if step_score > stay_score:
                curr[win_pos] = step_score
            else:
                curr[win_pos] = stay_score
        # swap prev and curr scores
        tmp = prev
        prev = curr
        curr = tmp

    cdef float score = prev[window_width - 1]
    free(stay_indices)
    free(step_indices)
    free(curr)
    free(prev)

    return score


cdef float score_all_paths_mod(
        np.ndarray[np.float32_t, ndim=2] tpost, np.ndarray[np.uintp_t] seq,
        np.ndarray[np.uintp_t] mod_cats,
        np.ndarray[np.uintp_t] can_mods_offsets, size_t tpost_start,
        size_t tpost_end, size_t nseq, size_t nstate):
    cdef size_t nbase = nstate_to_nbase(nstate - can_mods_offsets[4])
    cdef size_t ntrans_state = (nbase + nbase) * (nbase + 1)
    cdef size_t nblk = tpost_end - tpost_start
    cdef size_t window_width = nblk - nseq + 2

    cdef size_t * stay_indices = <size_t *> calloc(nseq, sizeof(size_t));
    cdef size_t * step_indices = <size_t *> calloc(nseq - 1, sizeof(size_t));
    #get_stay_step(seq, nseq, nbase, stay_indices, step_indices)
    cdef size_t * flop_mask_states = <size_t *> calloc(nseq, sizeof(size_t))
    stay_indices[0] = (seq[0] * (nbase + nbase) + seq[0]
                       if seq[0] < nbase else
                       nbase * (nbase + nbase) + seq[0])
    flop_mask_states[0] = seq[0]
    cdef size_t seq_pos, prev_fm_state, curr_fm_state
    for seq_pos in range(1, nseq):
        prev_fm_state = flop_mask_states[seq_pos - 1]
        if seq[seq_pos] == prev_fm_state:
            curr_fm_state = seq[seq_pos] + nbase
        else:
            curr_fm_state = seq[seq_pos]
        flop_mask_states[seq_pos] = curr_fm_state
        stay_indices[seq_pos] = (
            curr_fm_state * (nbase + nbase) + curr_fm_state
            if curr_fm_state < nbase else
            nbase * (nbase + nbase) + curr_fm_state)
        step_indices[seq_pos - 1] = (
            curr_fm_state * (nbase + nbase) + prev_fm_state
            if curr_fm_state < nbase else
            nbase * (nbase + nbase) + prev_fm_state)
    free(flop_mask_states)

    cdef float * curr = <float *> calloc(window_width, sizeof(float))
    cdef float * prev = <float *> calloc(window_width, sizeof(float))
    cdef float * tmp

    cdef size_t win_pos, trans_pos, stay_idx, step_idx, mod_idx
    cdef float stay_score, step_score, wp_score, pos_tpost, pos_mod_tpost
    # cumsum over stay in first seq pos to init prev
    prev[0] = 0.0
    stay_idx = stay_indices[0]
    for win_pos in range(1, window_width):
        wp_score = prev[win_pos - 1]
        trans_pos = tpost_start + win_pos - 1
        prev[win_pos] = wp_score + tpost[trans_pos, stay_idx]

    for seq_pos in range(1, nseq):
        wp_score = prev[0]
        stay_idx = stay_indices[seq_pos]
        step_idx = step_indices[seq_pos - 1]
        pos_tpost = tpost[tpost_start + seq_pos - 1, step_idx]
        mod_idx = ntrans_state + can_mods_offsets[seq[seq_pos]] + \
                  mod_cats[seq_pos]
        pos_mod_tpost = tpost[tpost_start + seq_pos - 1, mod_idx]
        curr[0] = wp_score + pos_tpost + pos_mod_tpost
        for win_pos in range(1, window_width):
            trans_pos = tpost_start + seq_pos + win_pos - 1

            # compute step score
            wp_score = prev[win_pos]
            pos_tpost = tpost[trans_pos, step_idx]
            pos_mod_tpost = tpost[trans_pos, mod_idx]
            step_score = wp_score + pos_tpost + pos_mod_tpost

            # compute stay score
            wp_score = curr[win_pos - 1]
            pos_tpost = tpost[trans_pos, stay_idx]
            stay_score = wp_score + pos_tpost

            # store Viterbi all paths score
            curr[win_pos] = fmaxf(stay_score, step_score) + log1pf(
                expf(-fabsf(stay_score - step_score)))
        # swap prev and curr scores
        tmp = prev
        prev = curr
        curr = tmp

    cdef float score = prev[window_width - 1]
    free(stay_indices)
    free(step_indices)
    free(curr)
    free(prev)

    return score

def score_mod_seq(
        np.ndarray[np.float32_t, ndim=2, mode="c"] tpost,
        np.ndarray[np.uintp_t, ndim=1, mode="c"] seq,
        np.ndarray[np.uintp_t, ndim=1, mode="c"] mod_cats,
        np.ndarray[np.uintp_t, ndim=1, mode="c"] can_mods_offsets,
        tpost_start, tpost_end, all_paths):
    nseq = seq.shape[0]
    nstate = tpost.shape[1]
    if all_paths:
        return score_all_paths_mod(tpost, seq, mod_cats, can_mods_offsets,
                                   tpost_start, tpost_end, nseq, nstate)
    return score_best_path_mod(tpost, seq, mod_cats, can_mods_offsets,
                               tpost_start, tpost_end, nseq, nstate)


##########################################################
###### Categorical modification flip-flop functions ######
##########################################################

@cython.wraparound(True)
def rle(x, tol=0):
    """  Run length encoding of array x

    Note: where matching is done with some tolerance, the first element
    of the run is chosen as representative.

    :param x: array
    :param tol: tolerance of match (for continuous arrays)

    :returns: tuple of array containing elements of x and array containing
    length of run
    """

    delta_x = np.ediff1d(x, to_begin=1)
    starts = np.where(np.absolute(delta_x) > tol)[0]
    last_runlength = len(x) - starts[-1]
    runlength = np.ediff1d(starts, to_end=last_runlength)

    return x[starts], runlength


@cython.wraparound(True)
def decode_post(
        np.ndarray[np.float32_t, ndim=2, mode="c"] r_post, alphabet=ALPHABET,
        np.ndarray[np.float32_t, ndim=2, mode="c"] mod_weights=None,
        np.ndarray[np.int64_t, ndim=1, mode="c"] can_nmods=None):
    """Decode a posterior using Viterbi algorithm for transducer.
    :param r_post: numpy array containing transducer posteriors.
    :param alphabet: alphabet corresponding to flip-flop labels.
    :returns: tuple containing (base calls, score and raw block positions).
    """
    nblock, nstate = r_post.shape[:2]
    nbase = len(set(alphabet))
    if nbase != nstate_to_nbase(nstate):
        raise NotImplementedError(
            'Incompatible decoding alphabet and posterior states.')

    path = np.zeros(nblock + 1, dtype=np.uintp)
    qpath = np.zeros(nblock + 1, dtype=np.float32)

    score = crf_flipflop_viterbi(r_post, path, qpath)

    # only process positions "transitioned into" along the path
    # first position doesn't have a score anyways
    # This aligned the indices of path and the posterior matricies
    runval, runlen = rle(path)
    basecall = ''.join(alphabet[int(b) % nbase] for b in runval)
    rl_cumsum = np.cumsum(np.concatenate([[0], runlen]))

    cdef size_t base_i, can_nmod, curr_can_pos, mod_i, len_can_nmods, all_mods_i
    cdef np.ndarray[np.float32_t, ndim=2] bc_matched_mod_weights
    mods_scores = None
    if mod_weights is not None:
        mods_scores = np.full((runval.shape[0], sum(can_nmods)), np.NAN,
                             dtype=np.float32)
        len_can_nmods = len(can_nmods)
        all_mods_i = 0
        # extract modified base probabilities for each modification included in
        # the input model
        # don't test first base since it is never "moved into"
        # and subtract 1 to align "moved into" indices
        bc_matched_mod_weights = mod_weights[rl_cumsum[1:-1] - 1]
        curr_can_pos = 0
        for base_i in range(len_can_nmods):
            can_nmod = can_nmods[base_i]
            if can_nmod > 0:
                base_poss = np.where(np.equal(np.mod(
                    runval[1:], len_can_nmods), base_i))[0]
            for mod_i in range(can_nmod):
                mods_scores[base_poss + 1, all_mods_i] = bc_matched_mod_weights[
                    base_poss, curr_can_pos + 1 + mod_i]
                all_mods_i += 1
            curr_can_pos += 1 + can_nmod

    return basecall, score, rl_cumsum, mods_scores
