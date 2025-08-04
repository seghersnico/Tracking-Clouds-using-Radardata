using Rasters
using NCDatasets
using GeoMakie, Makie
using Dates
using ArchGDAL       # Required for CRS handling
using GeoFormatTypes # Required for ProjString

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


function load_netcdf_radar_data(file_path::String)
    """
        load_netcdf_radar_data(file_path::String)

    Loads radar precipitation and quality data from a specified NetCDF file,
    processes it, and returns a `Rasters.RasterStack` containing the 'ACRR'
    (accumulated rainfall) and 'QUALITY' layers.

    The function handles the extraction of spatial coordinates (X, Y), time,
    and Coordinate Reference System (CRS) information from the NetCDF file.
    It reshapes 1D data into 2D (Y, X) and then into 3D (Y, X, Time) arrays,
    and constructs `Rasters.Raster` objects with appropriate dimensions, CRS,
    and `missingval` handling.

    # Arguments
    - `file_path::String`: The full path to the NetCDF file.

    # Returns
    - `Rasters.RasterStack`: A RasterStack containing two layers:
        - `:ACRR`: Accumulated rainfall data.
        - `:QUALITY`: Quality control data.

    # Throws
    - `ErrorException`: If the 'grid_mapping' variable is not found in the NetCDF file,
    as it's crucial for CRS extraction.
    - `KeyError`: If expected variables like "ACRR", "QUALITY", "X", "Y", or "time"
    are not found in the NetCDF file.
    """

    # STEP 1: Read raw data and coordinates using NCDatasets.jl
    ds = NCDataset(file_path)

    # Extract ACRR data array and its missing_value
    acrr_data_raw = ds["ACRR"][:]
    acrr_missing_value = get(ds["ACRR"].attrib, "missing_value", nothing)

    # Extract QUALITY data array and its missing_value
    quality_data_raw = ds["QUALITY"][:]
    quality_missing_value = get(ds["QUALITY"].attrib, "missing_value", nothing)

    # Extract X and Y coordinate arrays
    x_coords = ds["X"][:]
    y_coords = ds["Y"][:]

    # Extract the time dimension
    time_datetimes = ds["time"][:]

    # CRS EXTRACTION LOGIC
    proj_params = Dict{String, Any}()
    source_proj_string = ""

    if haskey(ds, "grid_mapping")
        grid_map_var = ds["grid_mapping"]
        for (attr_name, attr_value) in grid_map_var.attrib
            proj_params[attr_name] = attr_value
        end

        lat_0 = get(proj_params, "latitude_of_projection_origin", 90.0)
        lon_0 = get(proj_params, "straight_vertical_longitude_from_pole", 0.0)
        lat_ts = get(proj_params, "standard_parallel", 45.0)
        x_0 = get(proj_params, "false_easting", 0.0)
        y_0 = get(proj_params, "false_northing", 0.0)

        source_proj_string = "+proj=stere +lat_0=$(lat_0) +lon_0=$(lon_0) +lat_ts=$(lat_ts) +x_0=$(x_0) +y_0=$(y_0) +ellps=WGS84 +units=m +no_defs"
        # Verification using ArchGDAL is kept for robustness, although the variable itself isn't used
        verified_archgdal_crs = ArchGDAL.importCRS(GeoFormatTypes.ProjString(source_proj_string))

    else
        close(ds)
        error("The NetCDF file does not contain a 'grid_mapping' variable, which is required for CRS extraction.")
    end
    close(ds) # Close the file as soon as possible

    # STEP 2: Reshape the 1D data to (Y, X) and then to (Y, X, Ti)
    acrr_2d = reshape(acrr_data_raw, length(y_coords), length(x_coords))
    quality_2d = reshape(quality_data_raw, length(y_coords), length(x_coords))

    acrr_data_reshaped = reshape(acrr_2d, size(acrr_2d)..., 1)
    quality_data_reshaped = reshape(quality_2d, size(quality_2d)..., 1)

    # STEP 3: Explicitly construct Rasters.jl Dimension objects
    dims = (
        Rasters.Y(y_coords, lookup=Rasters.Projected(crs=GeoFormatTypes.ProjString(source_proj_string))),
        Rasters.X(x_coords, lookup=Rasters.Projected(crs=GeoFormatTypes.ProjString(source_proj_string))),
        Rasters.Ti(time_datetimes, lookup=Rasters.At(first(time_datetimes)))
    )

    # STEP 4: Create Raster objects, including the explicit missingval parameter
    raster_acrr = Rasters.Raster(acrr_data_reshaped, dims;
        crs=GeoFormatTypes.ProjString(source_proj_string),
        name=:ACRR,
        missingval=missing
    )
    raster_quality = Rasters.Raster(quality_data_reshaped, dims;
        crs=GeoFormatTypes.ProjString(source_proj_string),
        name=:QUALITY,
        missingval=missing
    )

    # STEP 5: Combine them into a RasterStack
    data_stack = Rasters.RasterStack(raster_acrr, raster_quality)

    return data_stack
end


## Plotting a Specific Radar File

# --- EXAMPLE USAGE TO GENERATE THE PLOT ---
println("Loading data... This might take a moment.")
# Specifically targeting this file for plotting
file_path_for_plot = "/home/nicoseghers/Datasets/radar_precipitation_france_1km_5min_202506/202506/20250602/cumul_france_1536-1km-5min_202506021825.nc"

# Load the data using your function
local_data_stack = try
    load_netcdf_radar_data(file_path_for_plot)
catch e
    println("Error loading data: ", e)
    rethrow(e) # Re-throw the error to stop execution if data loading fails
end

# Extract the ACRR raster from the loaded stack
raster_acrr_example = local_data_stack[:ACRR]

# Convert ACRR values to mm for better interpretation
acrr_mm_example = raster_acrr_example ./ 100.0

# Get X and Y coordinate values from the raster's lookup object.
x_coords_plot_example = Rasters.lookup(acrr_mm_example, Rasters.X) |> collect
y_coords_plot_example = Rasters.lookup(acrr_mm_example, Rasters.Y) |> collect

# Get the 2D data matrix.
data_to_plot_example = Rasters.values(acrr_mm_example)
data_to_plot_2d_example = data_to_plot_example[:, :, 1] # Select the 2D slice for the heatmap

# Step 1: Create a Figure and a GeoAxis
f_example = Figure(size = (800, 800))
ga_example = GeoAxis(f_example[1, 1],
    dest="+proj=longlat +datum=WGS84", # Destination projection for the map
    limits = ((-5, 10), (40, 55)),     # (lon_min, lon_max), (lat_min, lat_max)
    title = "Precipitation (ACRR) - Cumulative",
    xlabel = "Longitude",
    ylabel = "Latitude"
)

# Plot coastlines on the GeoAxis
lines!(ga_example, GeoMakie.coastlines())

# Step 2: Plot the raster data on the GeoAxis
precipitation_colormap_example = :turbid
precipitation_colorrange_example = (0.0, 50.0)

hm_example = heatmap!(ga_example, x_coords_plot_example, y_coords_plot_example, data_to_plot_2d_example,
    colormap = precipitation_colormap_example,
    colorrange = precipitation_colorrange_example
)

# Step 3: Add a Colorbar
Colorbar(f_example[1, 2], hm_example, label = "Precipitation (mm)", vertical = true)

# Step 4: Display the figure
f_example