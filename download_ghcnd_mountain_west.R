## ==========================================================================
## Download NOAA GHCN-Daily station data ("Daily Summaries") for the
## Mountain West (AZ, CO, ID, MT, NV, NM, UT, WY), Jan 2000 - Dec 2025
##
## Same data as https://www.ncei.noaa.gov/access/search/find-a-station/?datasetId=daily-summaries
## but fetched programmatically through NOAA's Access Data Service:
##   https://www.ncei.noaa.gov/access/services/data/v1?dataset=daily-summaries
## Station list: https://www.ncei.noaa.gov/pub/data/ghcn/daily/
##
## Run on your own computer:  Rscript download_ghcnd_mountain_west.R
## Needs: data.table (install.packages("data.table"))
## Optional: sf, to tag each station with its county FIPS (see county_file)
##
## Downloads are cached in ./ghcnd_raw/, so if it stops, re-run and it
## picks up where it left off.
##
## OUTPUT (./ghcnd_out/):
##   stations_mountain_west.csv   one row per station: id, name, state, lat,
##                                lon, elevation, county FIPS, elements, years
##   daily_<STATE>.csv            daily values, one file per state:
##                                station, date, prcp (mm), tmax/tmin/tavg (C)
##   monthly_station_summary.csv  small file: per station per month means,
##                                totals, growing degree-days, valid-day counts
## ==========================================================================

## ---- Settings ----------------------------------------------------------------
states     <- c("AZ", "CO", "ID", "MT", "NV", "NM", "UT", "WY")
start_date <- as.Date("2000-01-01")
end_date   <- as.Date("2025-12-31")
elements   <- c("PRCP", "TMAX", "TMIN", "TAVG")

# Which stations:
#   "temperature" = stations reporting TMAX and TMIN (about 2,000-3,000;
#                   they also report precipitation). Recommended.
#   "all"         = adds precipitation-only stations, mostly CoCoRaHS
#                   volunteers (many thousands, often short records).
#                   Several times longer to download.
station_set <- "temperature"

# Drop stations whose record overlaps 2000-2025 by fewer than this many years
min_years_overlap <- 5

stations_per_request <- 10      # stations per API call
pause_seconds        <- 0.5     # be polite to NOAA's server
gdd_base_c           <- 14.3    # WNV development threshold in Culex tarsalis

# Optional: county boundaries GeoJSON (the counties.geojson from the earlier
# analysis folder). If present and sf is installed, stations get a county FIPS.
county_file <- "counties.geojson"

raw_dir <- "ghcnd_raw"
out_dir <- "ghcnd_out"
api     <- "https://www.ncei.noaa.gov/access/services/data/v1"
meta    <- "https://www.ncei.noaa.gov/pub/data/ghcn/daily/"

suppressPackageStartupMessages(library(data.table))
dir.create(raw_dir, showWarnings = FALSE)
dir.create(out_dir, showWarnings = FALSE)
options(timeout = 600)

check <- function(desc, ok) {
  cat(sprintf("[%s] %s\n", ifelse(ok, "PASS", "FAIL"), desc))
  if (!ok) stop("Check failed: ", desc, call. = FALSE)
}

fetch <- function(url, dest, tries = 4) {
  if (file.exists(dest) && file.size(dest) > 0) return(TRUE)
  for (i in seq_len(tries)) {
    ok <- tryCatch({ download.file(url, dest, mode = "wb", quiet = TRUE); TRUE },
                   error = function(e) FALSE, warning = function(w) FALSE)
    if (ok && file.exists(dest) && file.size(dest) > 0) return(TRUE)
    if (file.exists(dest)) file.remove(dest)
    Sys.sleep(3 * i)
  }
  FALSE
}

## ---- 1. Station list ------------------------------------------------------------
cat("Downloading station list and inventory...\n")
check("Downloaded ghcnd-stations.txt",
      fetch(paste0(meta, "ghcnd-stations.txt"), file.path(raw_dir, "ghcnd-stations.txt")))
check("Downloaded ghcnd-inventory.txt",
      fetch(paste0(meta, "ghcnd-inventory.txt"), file.path(raw_dir, "ghcnd-inventory.txt")))

# Fixed-width layouts from NOAA's readme.txt
s <- readLines(file.path(raw_dir, "ghcnd-stations.txt"), warn = FALSE)
st <- data.table(id = substr(s, 1, 11),
                 lat = as.numeric(substr(s, 13, 20)),
                 lon = as.numeric(substr(s, 22, 30)),
                 elev_m = as.numeric(substr(s, 32, 37)),
                 state = trimws(substr(s, 39, 40)),
                 name = trimws(substr(s, 42, 71)))
st <- st[substr(id, 1, 2) == "US" & state %in% states]

v <- readLines(file.path(raw_dir, "ghcnd-inventory.txt"), warn = FALSE)
inv <- data.table(id = substr(v, 1, 11),
                  element = substr(v, 32, 35),
                  first = as.integer(substr(v, 37, 40)),
                  last = as.integer(substr(v, 42, 45)))
y0 <- as.integer(format(start_date, "%Y")); y1 <- as.integer(format(end_date, "%Y"))
inv <- inv[id %in% st$id & element %in% elements]
inv[, overlap := pmin(last, y1) - pmax(first, y0) + 1]
inv <- inv[overlap >= min_years_overlap]
check("Some stations overlap the requested period by at least min_years_overlap years",
      nrow(inv) > 0)

has <- dcast(inv, id ~ element, value.var = "overlap", fun.aggregate = max, fill = 0)
for (e in elements) if (!e %in% names(has)) has[, (e) := 0]
if (station_set == "temperature") {
  keep_ids <- has[TMAX > 0 & TMIN > 0, id]
} else {
  keep_ids <- has$id
}
st <- st[id %in% keep_ids]
st <- merge(st, inv[, .(elements = paste(sort(unique(element)), collapse = " "),
                        first_year = max(min(first), y0), last_year = min(max(last), y1)),
                    by = id], by = "id")
setorder(st, state, id)

cat(sprintf("\nStations selected (%s, >= %d years overlap):\n", station_set, min_years_overlap))
print(st[, .N, by = state])
check("Every state has at least one station", all(states %in% st$state))
n_req <- ceiling(nrow(st) / stations_per_request)
cat(sprintf("%d stations -> %d API requests. Rough time: %.0f-%.0f minutes.\n\n",
            nrow(st), n_req, n_req * 2 / 60, n_req * 6 / 60))

## Optional county FIPS for each station
st[, county_fips := NA_character_]
if (file.exists(county_file) && requireNamespace("sf", quietly = TRUE)) {
  cty <- sf::st_read(county_file, quiet = TRUE)
  cty$fips <- paste0(cty$STATE, cty$COUNTY)
  pts <- sf::st_as_sf(st, coords = c("lon", "lat"), crs = 4326, remove = FALSE)
  old <- sf::sf_use_s2(FALSE)
  j <- suppressMessages(sf::st_join(pts, sf::st_make_valid(cty[, "fips"]), join = sf::st_within))
  sf::sf_use_s2(old)
  st[, county_fips := j$fips[match(st$id, j$id)]]
  cat("Stations tagged with a county FIPS:", sum(!is.na(st$county_fips)), "of", nrow(st), "\n")
} else {
  cat("County tagging skipped (needs", county_file, "in this folder and the sf package).\n")
}
fwrite(st, file.path(out_dir, "stations_mountain_west.csv"))

## ---- 2. Download and process in batches ---------------------------------------------
# Outputs are rebuilt from the cache on every run, so re-running never duplicates rows
for (f in c(file.path(out_dir, paste0("daily_", states, ".csv")),
            file.path(out_dir, "monthly_station_summary.csv")))
  if (file.exists(f)) file.remove(f)

build_url <- function(ids) {
  paste0(api, "?dataset=daily-summaries",
         "&stations=", paste(ids, collapse = ","),
         "&startDate=", start_date, "&endDate=", end_date,
         "&dataTypes=", paste(elements, collapse = ","),
         "&units=metric&includeAttributes=true&format=csv")
}

# Parse one API response: blank out values whose quality flag (2nd attribute
# field) is set, i.e. values that failed a NOAA quality check
parse_batch <- function(path) {
  d <- tryCatch(fread(path, colClasses = "character", na.strings = c("", "NA")),
                error = function(e) NULL)
  if (is.null(d) || nrow(d) == 0 || !"STATION" %in% names(d)) return(NULL)
  out <- data.table(station = d$STATION, date = as.Date(d$DATE))
  n_flag <- 0L
  for (e in elements) {
    val <- if (e %in% names(d)) suppressWarnings(as.numeric(trimws(d[[e]]))) else rep(NA_real_, nrow(d))
    att <- paste0(e, "_ATTRIBUTES")
    if (att %in% names(d)) {
      q <- vapply(strsplit(ifelse(is.na(d[[att]]), "", d[[att]]), ",", fixed = TRUE),
                  function(x) if (length(x) >= 2) trimws(x[2]) else "", character(1))
      bad <- !is.na(val) & nzchar(q)
      n_flag <- n_flag + sum(bad)
      val[bad] <- NA
    }
    out[, (tolower(e)) := val]
  }
  attr(out, "n_flagged") <- n_flag
  out[!is.na(date)]
}

unit_mode <- NULL     # decided from the first data that contains July TMAX
fix_units <- function(d) {
  if (is.null(unit_mode)) {
    jul <- d[format(date, "%m") == "07" & !is.na(tmax), tmax]
    if (length(jul) < 30) return(d)
    m <- median(jul)
    unit_mode <<- if (m < 50) "metric" else if (m < 150) "fahrenheit" else "tenths"
    cat(sprintf("Median July TMAX in first data = %.1f -> units look like: %s\n", m, unit_mode))
  }
  if (unit_mode == "tenths") {
    for (e in c("prcp", "tmax", "tmin", "tavg")) d[, (e) := get(e) / 10]
  } else if (unit_mode == "fahrenheit") {
    for (e in c("tmax", "tmin", "tavg")) d[, (e) := (get(e) - 32) * 5 / 9]
    d[, prcp := prcp * 25.4]
  }
  d
}

batches <- split(st$id, ceiling(seq_len(nrow(st)) / stations_per_request))
failed <- character(0); n_rows <- 0; n_flagged <- 0; pending <- list()

process <- function(d) {
  d <- merge(d, st[, .(station = id, state)], by = "station")
  for (s_ in unique(d$state)) {
    fwrite(d[state == s_, .(station, date, prcp, tmax, tmin, tavg)],
           file.path(out_dir, paste0("daily_", s_, ".csv")), append = TRUE)
  }
  d[, tmean := fifelse(is.na(tavg), (tmax + tmin) / 2, tavg)]
  d[, `:=`(year = as.integer(format(date, "%Y")), month = as.integer(format(date, "%m")))]
  mon <- d[, .(prcp_total_mm = sum(prcp, na.rm = TRUE), prcp_days = sum(!is.na(prcp)),
               tmax_mean_c = mean(tmax, na.rm = TRUE), tmin_mean_c = mean(tmin, na.rm = TRUE),
               tmean_c = mean(tmean, na.rm = TRUE), temp_days = sum(!is.na(tmean)),
               gdd = sum(pmax(tmean - gdd_base_c, 0), na.rm = TRUE),
               days_tmax_ge32c = sum(tmax >= 32, na.rm = TRUE)),
           by = .(station, state, year, month)]
  for (cc in names(mon)) if (is.numeric(mon[[cc]])) set(mon, which(is.nan(mon[[cc]])), cc, NA)
  setnames(mon, "gdd", paste0("gdd_base", gdd_base_c))
  fwrite(mon, file.path(out_dir, "monthly_station_summary.csv"), append = TRUE)
  n_rows <<- n_rows + nrow(d)
}

t0 <- Sys.time()
for (b in seq_along(batches)) {
  ids <- batches[[b]]
  # Cache name describes exactly what was requested, so changing any setting
  # can never reuse a cached file that holds different stations or dates
  f <- file.path(raw_dir, sprintf("b_%s_%s_n%d_%s_%s_%s.csv", ids[1], ids[length(ids)],
                                  length(ids), start_date, end_date, paste(elements, collapse = "")))
  ok <- file.exists(f) && file.size(f) > 0
  if (!ok) { ok <- fetch(build_url(ids), f); Sys.sleep(pause_seconds) }
  d <- if (ok) parse_batch(f) else NULL

  if (is.null(d)) {                          # batch failed: try stations one by one
    parts <- lapply(ids, function(i) {
      fi <- file.path(raw_dir, sprintf("s_%s_%s_%s_%s.csv", i, start_date, end_date,
                                       paste(elements, collapse = "")))
      if (!fetch(build_url(i), fi)) { failed <<- c(failed, i); return(NULL) }
      Sys.sleep(pause_seconds); parse_batch(fi)
    })
    parts <- Filter(Negate(is.null), parts)
    n_part_flags <- sum(vapply(parts, function(p) as.numeric(attr(p, "n_flagged")), numeric(1)))
    d <- rbindlist(parts, fill = TRUE)
    if (nrow(d) == 0) next
    attr(d, "n_flagged") <- n_part_flags
  }
  n_flagged <- n_flagged + ifelse(is.null(attr(d, "n_flagged")), 0, attr(d, "n_flagged"))

  # Hold data until units are confirmed, then process everything held
  d <- fix_units(d)
  if (is.null(unit_mode)) { pending[[length(pending) + 1]] <- d; next }
  if (length(pending)) { for (p in pending) process(fix_units(p)); pending <- list() }
  process(d)

  if (b %% 10 == 0 || b == length(batches)) {
    el <- as.numeric(difftime(Sys.time(), t0, units = "mins"))
    cat(sprintf("  batch %d/%d  (%.0f min elapsed, ~%.0f min left)\n",
                b, length(batches), el, el / b * (length(batches) - b)))
  }
}
if (length(pending)) {               # never saw enough July data to decide; assume metric
  unit_mode <- "metric"; for (p in pending) process(p)
}

## ---- 3. Checks ------------------------------------------------------------------------
cat("\n================ CHECKS ================\n")
if (length(failed)) {
  cat("[WARN]", length(failed), "stations could not be downloaded (listed in failed_stations.txt)\n")
  writeLines(failed, file.path(out_dir, "failed_stations.txt"))
}
cat("Values removed for failing NOAA quality checks:", n_flagged, "\n")
mon <- fread(file.path(out_dir, "monthly_station_summary.csv"))
check("Data was retrieved for most selected stations (> 90%)",
      uniqueN(mon$station) / nrow(st) > 0.9)
check("Dates stay within the requested period",
      min(mon$year) >= y0 && max(mon$year) <= y1)
jul <- mon[month == 7 & temp_days >= 20]
check("July mean daily max is plausible for the region (median 20-38 C)",
      median(jul$tmax_mean_c, na.rm = TRUE) > 20 && median(jul$tmax_mean_c, na.rm = TRUE) < 38)
check("Monthly precipitation totals are non-negative and below 1,000 mm",
      all(mon$prcp_total_mm >= 0 & mon$prcp_total_mm < 1000, na.rm = TRUE))
slc <- mon[station == "USW00024127" & month == 7 & temp_days >= 20]
if (nrow(slc)) cat(sprintf("Salt Lake City airport, July mean high: %.1f C (expect about 33-35)\n",
                           mean(slc$tmax_mean_c)))

cat(sprintf("\nDone in %.0f minutes. %s daily rows from %d stations.\n",
            as.numeric(difftime(Sys.time(), t0, units = "mins")),
            format(n_rows, big.mark = ","), uniqueN(mon$station)))
cat("Outputs are in", normalizePath(out_dir), "\n")
cat("For the analysis, upload: stations_mountain_west.csv and monthly_station_summary.csv\n")
cat("(the daily files are large; keep them for later).\n")
