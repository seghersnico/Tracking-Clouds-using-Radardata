using Rasters       
using NCDatasets
using GeoMakie, Makie
using ImageMorphology
using ImageFiltering
using Dates
using Statistics


const BASE_DATA_DIR = "/radar_precipitation_france_1km_5min_202506"
const TIME_STEP_MINUTES = 5         # Time step of the radar files in minutes
const PRECIPITATION_THRESHOLD = 50  # units are 1/100 mm
const QUALITY_THRESHOLD = 10 
const START_DATETIME = DateTime(2025, 6, 2, 15, 0)  # June 2, 2025, 02:00
const END_DATETIME = DateTime(2025, 6, 2, 23, 0)    # June 3, 2025, 22:0

const ALPS_LON_MIN, ALPS_LON_MAX = -3.0, 9.0
const ALPS_LAT_MIN, ALPS_LAT_MAX = 43.0, 49.0


function get_radar_file_paths(base_dir, start_dt::DateTime, end_dt::DateTime, time_step_minutes::Int)
    """
    Generates a list of file paths for radar NetCDF files within a specified
    date range and time step.

    This function searches the directory structure under `base_dir` for files that
    match the expected filename format (`cumul_france_...`) for every
    `time_step_minutes` between `start_dt` and `end_dt`. Only paths to existing files
    are included in the returned list. Missing files are silently skipped.

    # Arguments
    - `base_dir::String`: The base directory where the radar data is stored.
    Expects a structure like `base_dir/YYYYMM/YYYYMMDD/filename.nc`.
    - `start_dt::DateTime`: The start date and time (inclusive) for searching files.
    - `end_dt::DateTime`: The end date and time (inclusive) for searching files.
    - `time_step_minutes::Int`: The interval in minutes between successive radar files.

    # Returns
    - `Vector{String}`: An array of full paths to the found NetCDF files.
    This list only includes files that are actually present on disk.
    """

    file_paths = String[]
    current_dt = start_dt

    while current_dt <= end_dt
        time_str = Dates.format(current_dt, "yyyymmddHHMM")
        filename = "cumul_france_1536-1km-5min_$(time_str).nc"
        month_dir = Dates.format(current_dt, "yyyymm")
        day_dir = Dates.format(current_dt, "yyyymmdd")
        filepath = joinpath(base_dir, month_dir, day_dir, filename)

        if isfile(filepath)
            push!(file_paths, filepath)
        else
            println("Warning: File not found: $filepath")
        end
        current_dt += Minute(time_step_minutes)
    end
    return file_paths
end

radar_file_paths = get_radar_file_paths(BASE_DATA_DIR, START_DATETIME, END_DATETIME, TIME_STEP_MINUTES)
if isempty(radar_file_paths)
    error("No radar files found. Check BASE_DATA_DIR and the date ranges.")
end
println("$(length(radar_file_paths)) radar files found.")
radar_file_paths