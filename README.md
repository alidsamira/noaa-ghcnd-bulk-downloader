# NOAA GHCN-Daily Bulk Downloader for the Mountain West

R script to retrieve and process NOAA Global Historical Climatology Network Daily (GHCN-Daily) observations for eight U.S. Mountain West states using NOAA's National Centers for Environmental Information (NCEI) Access Data Service.

The project downloads station-level daily weather records, applies quality-flag screening, and generates state-level daily files and station-level monthly climate summaries. It supports cached downloads, retries, and optional county FIPS assignment.

## Geographic and temporal coverage

- **States:** Arizona (AZ), Colorado (CO), Idaho (ID), Montana (MT), Nevada (NV), New Mexico (NM), Utah (UT), Wyoming (WY)
- **Default dates:** January 1, 2000 – December 31, 2025
- **Variables:** precipitation (`PRCP`), maximum temperature (`TMAX`), minimum temperature (`TMIN`), average temperature (`TAVG`)
- **Station selection:** By default, retain stations with qualifying records for both maximum and minimum temperature and at least five years of record overlap with the target period. An `all` mode broadens selection to stations reporting any of the requested elements.

## Requirements

- R
- [`data.table`](https://cran.r-project.org/package=data.table) (required)
- [`sf`](https://cran.r-project.org/package=sf) (optional, for county FIPS assignment)
- Network connection to NOAA NCEI services

Install the required R package:

```r
install.packages("data.table")
```

To use optional county tagging:

```r
install.packages("sf")
```

## Quick start

Clone the repository (or download the R script), then run from the project folder:

```bash
Rscript download_ghcnd_mountain_west.R
```

The script creates `ghcnd_raw/` for cached download files and `ghcnd_out/` for processed outputs.

## Configuration

Edit the **Settings** section at the top of `download_ghcnd_mountain_west.R` to customize:

| Setting | Default | Purpose |
| --- | --- | --- |
| `states` | `AZ, CO, ID, MT, NV, NM, UT, WY` | States to include |
| `start_date`, `end_date` | `2000-01-01`, `2025-12-31` | Requested date range |
| `elements` | `PRCP, TMAX, TMIN, TAVG` | NOAA daily data types |
| `station_set` | `"temperature"` | Use `"all"` to include precipitation-only stations |
| `min_years_overlap` | `5` | Minimum number of years of station record overlap |
| `stations_per_request` | `10` | Stations per NOAA API request |
| `pause_seconds` | `0.5` | Delay between requests |
| `gdd_base_c` | `14.3` | Degree-day calculation base in Celsius |
| `county_file` | `counties.geojson` | Optional local county polygons for FIPS tagging |

## Generated files

Outputs are written under `ghcnd_out/`:

| File | Description |
| --- | --- |
| `stations_mountain_west.csv` | Station identifiers, coordinates, elevation, state, available elements, record years, and optional county FIPS |
| `daily_<STATE>.csv` | Daily station observations for each state: `station`, `date`, `prcp`, `tmax`, `tmin`, `tavg` |
| `monthly_station_summary.csv` | Monthly station-level precipitation, temperature summaries, growing degree-days, count of days with Tmax ≥ 32°C, and observation-day counts |
| `failed_stations.txt` | List of failed station downloads, when applicable |

The monthly summary calculates mean daily temperature using `TAVG` if available and otherwise `(TMAX + TMIN)/2`.

**Units:** The script requests metric units from NOAA and includes additional unit-detection and conversion logic. Expected processed units are millimeters for precipitation and Celsius for temperature.

## Reliability and data considerations

- Responses are cached under `ghcnd_raw/` so rerunning the script can reuse previously downloaded files.
- Failed batches are retried as individual stations.
- Values with a nonempty NOAA quality flag in the response attributes are replaced with missing values.
- The script prints plausibility and coverage checks after processing.
- Monthly precipitation totals and temperature summaries are based on available observations; review `prcp_days` and `temp_days` before treating incomplete months as complete.
- Minimum years of inventory overlap does **not** guarantee uninterrupted observations or complete daily coverage.
- The optional county FIPS step requires a compatible `counties.geojson` containing `STATE` and `COUNTY` fields; that file is not included here.

**Execution status:** This repository packages the supplied script; it has not been end-to-end tested against NOAA's live API as part of preparing this README.

## Data source and acknowledgment

Data come from NOAA's **Global Historical Climatology Network Daily (GHCN-Daily)**, accessed via NCEI:

- [NOAA NCEI Daily Summaries search](https://www.ncei.noaa.gov/access/search/find-a-station/?datasetId=daily-summaries)
- [NOAA NCEI Access Data Service](https://www.ncei.noaa.gov/access/services/data/v1?dataset=daily-summaries)
- [GHCN-Daily station inventory and metadata](https://www.ncei.noaa.gov/pub/data/ghcn/daily/)

Please acknowledge NOAA NCEI/GHCN-Daily when using these data in research or derived datasets.

