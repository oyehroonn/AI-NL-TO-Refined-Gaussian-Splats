import os
import subprocess
import argparse
import time
import datetime
from shutil import copy2, move

# ── Matcher auto-selection ────────────────────────────────────────────────────
# After Layer 2 filtering, frame count is typically 80-150.
# At that size, exhaustive_matcher (all-pairs) is feasible and dramatically
# better than sequential: test_dataset exhaustive = 4,950 pairs vs
# our sequential = 1,745 pairs for similar frame counts.
_AUTO_EXHAUSTIVE_THRESHOLD = 150   # frames ≤ this → use exhaustive
_SEQUENTIAL_OVERLAP_DEFAULT = 20   # overlap window for sequential (default COLMAP is 10)

def rename_image_folder_if_needed(image_path):
    # Rename the image_path folder to "source" if it's named "input" or "images"
    parent_dir = os.path.abspath(os.path.join(image_path, os.pardir))
    current_folder_name = os.path.basename(os.path.normpath(image_path))
    
    if current_folder_name in ["input", "images"]:
        new_image_path = os.path.join(parent_dir, "source")
        os.rename(image_path, new_image_path)
        print(f"Renamed image folder from {current_folder_name} to: {new_image_path}")
        return new_image_path
    return image_path

def filter_images(image_path, interval):
    parent_dir = os.path.abspath(os.path.join(image_path, os.pardir))
    input_folder = os.path.join(parent_dir, 'input')

    if interval > 1:
        if not os.path.exists(input_folder):
            os.makedirs(input_folder)

        image_files = sorted([f for f in os.listdir(image_path) if os.path.isfile(os.path.join(image_path, f))])
        filtered_files = image_files[::interval]

        for file in filtered_files:
            copy2(os.path.join(image_path, file), os.path.join(input_folder, file))

        return input_folder
    return image_path

def _count_images(folder: str) -> int:
    """Count image files in a folder (for auto-matcher selection)."""
    exts = {'.jpg', '.jpeg', '.png', '.bmp', '.tif', '.tiff'}
    try:
        return sum(
            1 for f in os.listdir(folder)
            if os.path.splitext(f.lower())[1] in exts
        )
    except Exception:
        return 0


def _select_matcher(
    image_path: str,
    requested_matcher: str,
    auto_select: bool,
    sequential_overlap: int,
    log_file,
    exhaustive_threshold: int = _AUTO_EXHAUSTIVE_THRESHOLD,
) -> tuple[str, str]:
    """
    Decide which matcher command to use.

    Returns (matcher_name, full_command_suffix) where the suffix includes
    any extra flags (e.g. --SequentialMatching.overlap).
    """
    n_images = _count_images(image_path)
    msg_prefix = f"[COLMAP] {n_images} images in {image_path}."

    if auto_select and n_images <= exhaustive_threshold:
        # Exhaustive: every pair matched. Best for ≤threshold frames.
        # Pair count = n*(n-1)/2. e.g. 100 frames = 4,950 pairs.
        n_pairs = n_images * (n_images - 1) // 2
        decision = f"AUTO: exhaustive_matcher ({n_pairs} pairs — all-vs-all)"
        log_file.write(f"{msg_prefix} {decision}\n")
        print(f"{msg_prefix} {decision}")
        return "exhaustive_matcher", ""
    else:
        if auto_select:
            decision = (
                f"AUTO: sequential_matcher (>{exhaustive_threshold} frames, "
                f"overlap={sequential_overlap})"
            )
        else:
            decision = f"MANUAL: {requested_matcher} (overlap={sequential_overlap})"
        log_file.write(f"{msg_prefix} {decision}\n")
        print(f"{msg_prefix} {decision}")
        overlap_flag = (
            f" --SequentialMatching.overlap {sequential_overlap}"
            if requested_matcher == "sequential_matcher"
            else ""
        )
        return requested_matcher, overlap_flag


def run_colmap(
    image_path,
    matcher_type,
    interval,
    model_type,
    auto_select_matcher: bool = True,
    sequential_overlap: int = _SEQUENTIAL_OVERLAP_DEFAULT,
    exhaustive_threshold: int = _AUTO_EXHAUSTIVE_THRESHOLD,
):
    # Rename the image_path folder if needed
    image_path = rename_image_folder_if_needed(image_path)

    parent_dir = os.path.abspath(os.path.join(image_path, os.pardir))
    image_path = filter_images(image_path, interval)

    distorted_folder = os.path.join(parent_dir, 'distorted')
    database_path = os.path.join(distorted_folder, 'database.db')
    database_global_path = os.path.join(distorted_folder, 'database_global.db')
    sparse_mapper_out = os.path.join(distorted_folder, 'sparse')
    sparse_folder = os.path.join(parent_dir, 'sparse')  # Top-level sparse folder
    sparse_zero_folder = os.path.join(sparse_folder, '0')  # The new subfolder we want to create

    os.makedirs(distorted_folder, exist_ok=True)
    os.makedirs(sparse_folder, exist_ok=True)
    os.makedirs(sparse_mapper_out, exist_ok=True)

    log_file_path = os.path.join(parent_dir, "colmap_run.log")
    total_start_time = time.time()

    # Feature extraction + matching, then global SfM via COLMAP 4.x (GLOMAP merged into colmap global_mapper).
    # view_graph_calibrator mutates the DB; use a copy per https://colmap.github.io/cli.html
    # Camera model: SIMPLE_PINHOLE (1 focal param) is more stable than PINHOLE for single-camera video.
    with open(log_file_path, "w") as log_file:
        log_file.write(f"COLMAP run started at: {datetime.datetime.now()}\n")

        actual_matcher, matcher_flags = _select_matcher(
            image_path, matcher_type, auto_select_matcher, sequential_overlap, log_file,
            exhaustive_threshold=exhaustive_threshold,
        )

        commands = [
            f"colmap feature_extractor --image_path {image_path} --database_path {database_path} --ImageReader.single_camera 1 --ImageReader.camera_model SIMPLE_PINHOLE",
            f"colmap {actual_matcher} --database_path {database_path}{matcher_flags}",
        ]
        global_commands = [
            f"colmap view_graph_calibrator --database_path {database_global_path}",
            f"colmap global_mapper --database_path {database_global_path} --image_path {image_path} --output_path {sparse_mapper_out}",
        ]

        for command in commands:
            command_start_time = time.time()
            log_file.write(f"Running command: {command}\n")
            subprocess.run(command, shell=True, check=True)
            command_end_time = time.time()
            command_elapsed_time = command_end_time - command_start_time
            log_file.write(f"Time taken for command: {command_elapsed_time:.2f} seconds\n")
            print(f"Time taken for command: {command_elapsed_time:.2f} seconds")

        copy_start = time.time()
        log_file.write(f"Copying {database_path} -> {database_global_path} for global SfM (view graph calibration mutates DB)\n")
        print(f"Copying database to {database_global_path} for global mapper pipeline...")
        copy2(database_path, database_global_path)
        copy_elapsed = time.time() - copy_start
        log_file.write(f"Time taken for database copy: {copy_elapsed:.2f} seconds\n")
        print(f"Time taken for database copy: {copy_elapsed:.2f} seconds")

        for command in global_commands:
            command_start_time = time.time()
            log_file.write(f"Running command: {command}\n")
            subprocess.run(command, shell=True, check=True)
            command_end_time = time.time()
            command_elapsed_time = command_end_time - command_start_time
            log_file.write(f"Time taken for command: {command_elapsed_time:.2f} seconds\n")
            print(f"Time taken for command: {command_elapsed_time:.2f} seconds")

        if model_type == '3dgs':
            img_undist_cmd = (
                f"colmap image_undistorter "
                f"--image_path {image_path} "
                f"--input_path {os.path.join(distorted_folder, 'sparse/0')} "  # Use the sparse/0 in distorted
                f"--output_path {parent_dir} "  # Output undistorted results to the top-level folder
                f"--output_type COLMAP"
            )
            log_file.write(f"Running command: {img_undist_cmd}\n")
            undistort_start_time = time.time()
            exit_code = os.system(img_undist_cmd)
            undistort_end_time = time.time()
            undistort_elapsed_time = undistort_end_time - undistort_start_time

            if exit_code != 0:
                log_file.write(f"Undistortion failed with code {exit_code}. Exiting.\n")
                print(f"Undistortion failed with code {exit_code}. Exiting.")
                exit(exit_code)
            else:
                log_file.write(f"Time taken for undistortion: {undistort_elapsed_time:.2f} seconds\n")
                print(f"Time taken for undistortion: {undistort_elapsed_time:.2f} seconds")

        # Move the cameras.bin, images.bin, and points3D.bin files to sparse/0 in the top-level folder
        os.makedirs(sparse_zero_folder, exist_ok=True)
        for file_name in ['cameras.bin', 'images.bin', 'points3D.bin']:
            source_file = os.path.join(sparse_folder, file_name)
            dest_file = os.path.join(sparse_zero_folder, file_name)
            if os.path.exists(source_file):
                move(source_file, dest_file)
                log_file.write(f"Moved {file_name} to {sparse_zero_folder}\n")
                print(f"Moved {file_name} to {sparse_zero_folder}")

        total_end_time = time.time()
        total_elapsed_time = total_end_time - total_start_time
        log_file.write(f"COLMAP run finished at: {datetime.datetime.now()}\n")
        log_file.write(f"Total time taken: {total_elapsed_time:.2f} seconds\n")
        print(f"Total time taken: {total_elapsed_time:.2f} seconds")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Run COLMAP feature extraction, matching, view-graph calibration, and global_mapper (COLMAP 4.x global SfM)."
    )
    parser.add_argument('--image_path', required=True, help="Path to the images folder.")
    parser.add_argument('--matcher_type', default='sequential_matcher', choices=['sequential_matcher', 'exhaustive_matcher'], 
                        help="Type of matcher to use (default: sequential_matcher).")
    parser.add_argument('--interval', type=int, default=1, help="Interval of images to use (default: 1, meaning all images).")
    parser.add_argument('--model_type', default='3dgs', choices=['3dgs', 'nerfstudio'], 
                        help="Model type to run. '3dgs' includes undistortion, 'nerfstudio' skips undistortion.")

    args = parser.parse_args()

    run_colmap(args.image_path, args.matcher_type, args.interval, args.model_type)
