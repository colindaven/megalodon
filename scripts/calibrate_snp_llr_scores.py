import os
import sys
import argparse
from collections import defaultdict

import matplotlib
if sys.platform == 'darwin':
    matplotlib.use("TkAgg")
import matplotlib.pyplot as plt
from matplotlib.backends.backend_pdf import PdfPages

import numpy as np

from megalodon import calibration


def plot_calib(
        pdf_fp, snp_type, smooth_ls, s_ref, sm_ref, s_alt, sm_alt,
        mono_prob, prob_alt):
    f, axarr = plt.subplots(3, sharex=True, figsize=(11, 7))
    axarr[0].plot(smooth_ls, s_ref, color='orange')
    axarr[0].plot(smooth_ls, sm_ref, color='red')
    axarr[0].plot(smooth_ls, s_alt, color='grey')
    axarr[0].plot(smooth_ls, sm_alt, color='blue')
    axarr[0].set_ylabel(
        'Probability Density\nred/orange=canonical\nblue/grey=modified')
    axarr[0].set_title(snp_type + ' Calibration')
    axarr[1].plot(smooth_ls, mono_prob, color='orange')
    axarr[1].plot(
        smooth_ls, 1 / (np.exp(smooth_ls) + 1), color='purple')
    axarr[1].set_ylabel(
        'Emperical Modified\nProbability\norange=calibrated\npurple=raw')
    axarr[2].plot(
        smooth_ls, np.log((1 - prob_alt) / prob_alt), color='red')
    axarr[2].plot(
        smooth_ls, np.log((1 - mono_prob) / mono_prob), color='orange')
    axarr[2].set_ylabel('Calibrated LLR\norage=monotonic')
    axarr[2].set_xlabel('Theoretical LLR (NN Score)')
    pdf_fp.savefig(bbox_inches='tight')
    plt.close()
    return

def extract_llrs(llr_fn, max_indel_len=None):
    snp_ref_llrs, ins_ref_llrs, del_ref_llrs = (
        defaultdict(list) for _ in range(3))
    with open(llr_fn) as llr_fp:
        for line in llr_fp:
            is_ref_correct, llr, ref_seq, alt_seq = line.split()
            llr = float(llr)
            if is_ref_correct != 'True': continue
            if np.isnan(llr): continue
            if (max_indel_len is not None and
                np.abs(len(ref_seq) - len(alt_seq)) > max_indel_len):
                continue
            if len(ref_seq) == 1 and len(alt_seq) == 1:
                snp_ref_llrs[(ref_seq, alt_seq)].append(llr)
            else:
                if len(ref_seq) > len(alt_seq):
                    del_ref_llrs[len(ref_seq) - len(alt_seq)].append(llr)
                else:
                    ins_ref_llrs[len(alt_seq) - len(ref_seq)].append(llr)

    return snp_ref_llrs, ins_ref_llrs, del_ref_llrs


def prep_out(out_fn, overwrite):
    if os.path.exists(out_fn):
        if overwrite:
            os.remove(out_fn)
        else:
            raise NotImplementedError(
                'ERROR: --out-filename exists and --overwrite not set.')
    try:
        open(out_fn, 'w').close()
        os.remove(out_fn)
    except:
        sys.stderr.write(
            '*' * 60 + '\nERROR: Attempt to write to --out-filename location ' +
            'failed with the following error.\n' + '*' * 60 + '\n\n')
        raise

    return


def get_parser():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        '--ground-truth-llrs', default='snp_calibration_statistics.txt',
        help='Ground truth log-likelihood ratio statistics (produced by ' +
        'generate_ground_truth_snp_llr_scores.py). Default: %(default)s')
    parser.add_argument(
        '--max-input-llr', type=int, default=calibration.DEFAULT_SMOOTH_MAX,
        help='Maximum log-likelihood ratio to compute calibration. ' +
        'Default: %(default)d')
    parser.add_argument(
        '--num-calibration-values', type=int,
        default=calibration.DEFAULT_SMOOTH_NVALS,
        help='Number of discrete calibration values to compute. ' +
        'Default: %(default)d')
    parser.add_argument(
        '--smooth-bandwidth', type=float, default=calibration.DEFAULT_SMOOTH_BW,
        help='Smoothing bandwidth. Default: %(default)f')
    parser.add_argument(
        '--min-density', type=float, default=calibration.DEFAULT_MIN_DENSITY,
        help='Minimum density value to compute calibration. This value ' +
        'dynamically adjusts [--max-input-llr] when it is too large. ' +
        'Default: %(default)f')
    parser.add_argument(
        '--out-filename', default='megalodon_snp_calibration.npz',
        help='Filename to output calibration values. Default: %(default)s')
    parser.add_argument(
        '--out-pdf',
        help='Output pdf filename for modified base calibration ' +
        'visualization. Default: Do not produce plot.')
    parser.add_argument(
        '--overwrite', action='store_true',
        help='Overwrite --out-filename if it exists.')

    return parser


def main():
    args = get_parser().parse_args()

    prep_out(args.out_filename, args.overwrite)

    sys.stderr.write('Parsing log-likelihood ratios\n')
    snp_ref_llrs, ins_ref_llrs, del_ref_llrs = extract_llrs(
        args.ground_truth_llrs)
    # add calibration for a generic SNP (mostly multiple SNPs
    # as single variant; but not an indel)
    generic_snp_llrs = [llr for snp_type_llrs in snp_ref_llrs.values()
                        for llr in snp_type_llrs]
    # downsample to same level as other snp types
    snp_ref_llrs[
        (calibration.GENERIC_BASE,
         calibration.GENERIC_BASE)] = np.random.choice(
             generic_snp_llrs, int(len(generic_snp_llrs) / 12), replace=False)
    max_indel_len = max(ins_ref_llrs)
    assert set(ins_ref_llrs) == set(del_ref_llrs), (
            'Must test same range of lengths for insertions and deletions')
    assert set(ins_ref_llrs) == set(range(1, max_indel_len + 1)), (
        'Must test every length in length range for indels')

    pdf_fp = None if args.out_pdf is None else PdfPages(args.out_pdf)
    sys.stderr.write('Computing stratified single-base SNP calibration.\n')
    snp_calibs = {}
    for (ref_seq, alt_seq), snp_llrs in sorted(snp_ref_llrs.items()):
        sys.stderr.write('Computing ' + ref_seq + ' -> ' + alt_seq +
                         ' SNP calibration.\n')
        snp_calib, snp_llr_range, plot_data \
            = calibration.compute_mirrored_calibration(
                np.array(snp_llrs), args.max_input_llr,
                args.num_calibration_values, args.smooth_bandwidth,
                args.min_density, pdf_fp is not None)
        snp_calibs[(ref_seq, alt_seq)] = (snp_calib, snp_llr_range)
        if pdf_fp is not None:
            plot_calib(pdf_fp, 'SNP: ' + ref_seq + ' -> ' + alt_seq, *plot_data)
    sys.stderr.write('Computing deletion calibration.\n')
    del_calibs = {}
    for del_len, del_llrs in sorted(del_ref_llrs.items()):
        sys.stderr.write('Computing deletion length {} calibration.\n'.format(
            del_len))
        del_calib, del_llr_range, plot_data \
            = calibration.compute_mirrored_calibration(
                np.array(del_llrs), args.max_input_llr,
                args.num_calibration_values, args.smooth_bandwidth,
                args.min_density, pdf_fp is not None)
        del_calibs[del_len] = (del_calib, del_llr_range)
        if pdf_fp is not None:
            plot_calib(pdf_fp, 'Deletion Length ' + str(del_len), *plot_data)
    sys.stderr.write('Computing insertion calibration.\n')
    ins_calibs = {}
    for ins_len, ins_llrs in sorted(ins_ref_llrs.items()):
        sys.stderr.write('Computing insertion length {} calibration.\n'.format(
            ins_len))
        ins_calib, ins_llr_range, plot_data \
            = calibration.compute_mirrored_calibration(
                np.array(ins_llrs), args.max_input_llr,
                args.num_calibration_values, args.smooth_bandwidth,
                args.min_density, pdf_fp is not None)
        ins_calibs[ins_len] = (ins_calib, ins_llr_range)
        if pdf_fp is not None:
            plot_calib(pdf_fp, 'Insertion Length ' + str(ins_len), *plot_data)

    if pdf_fp is not None:
        pdf_fp.close()

    # save calibration table for reading into SNP table
    sys.stderr.write('Saving calibrations to file.\n')
    snp_llr_range_save_data, snp_calib_save_data = {}, {}
    for (ref_seq, alt_seq), (snp_calib, snp_llr_range) in snp_calibs.items():
        snp_calib_save_data[
            calibration.SNP_CALIB_TMPLT.format(ref_seq, alt_seq)] = snp_calib
        snp_llr_range_save_data[
            calibration.SNP_LLR_RNG_TMPLT.format(
                ref_seq, alt_seq)] = snp_llr_range
    del_llr_range_save_data, del_calib_save_data = {}, {}
    for del_len, (del_calib, del_llr_range) in del_calibs.items():
        del_calib_save_data[
            calibration.DEL_CALIB_TMPLT.format(del_len)] = del_calib
        del_llr_range_save_data[
            calibration.DEL_LLR_RNG_TMPLT.format(del_len)] = del_llr_range
    ins_llr_range_save_data, ins_calib_save_data = {}, {}
    for ins_len, (ins_calib, ins_llr_range) in ins_calibs.items():
        ins_calib_save_data[
            calibration.INS_CALIB_TMPLT.format(ins_len)] = ins_calib
        ins_llr_range_save_data[
            calibration.INS_LLR_RNG_TMPLT.format(ins_len)] = ins_llr_range
    np.savez(
        args.out_filename,
        stratify_type=calibration.SNP_CALIB_TYPE,
        smooth_nvals=args.num_calibration_values,
        max_indel_len=max_indel_len,
        **snp_calib_save_data,
        **snp_llr_range_save_data,
        **del_calib_save_data,
        **del_llr_range_save_data,
        **ins_calib_save_data,
        **ins_llr_range_save_data
    )

    return


if __name__ == '__main__':
    main()
