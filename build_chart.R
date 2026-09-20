
# build_chart.R -------------------------------------------------------------
# Reads Case_data.csv, applies small-cell suppression, and writes index.html:
# a standalone page reproducing the Shiny chart with no R server behind it.
#
# Run:  source("build_chart.R", echo = TRUE)
#
# Needs these three files in the project folder:
#   Case_data.csv
#   chart_template.html
#   build_chart.R  (this file)
# ---------------------------------------------------------------------------

PROJECT_DIR <- "~/R/Cases_Dashboard"
setwd(PROJECT_DIR)

library(tidyverse)
library(lubridate)
library(jsonlite)

# --- Settings to review each refresh --------------------------------------
IN_CSV     <- "Case_data.csv"
TEMPLATE   <- "chart_template.html"
OUT_HTML   <- "index.html"
OUT_AUDIT  <- "published_data.csv"   # exact copy of what goes public

YEARS      <- 2018:2026
CURRENT_YR <- 2026                   # gets the asterisk and the footnote
AS_OF      <- "06/30/2026"           # update with each data pull
THRESHOLD  <- 5                      # counts below this are suppressed

# Disclosure control for rare conditions.
# A condition that never reaches THRESHOLD in ANY county-year is shown
# district-wide only, with no county breakdown. Otherwise a single dot on a
# county chart says "this named county had 1-4 cases in this named year",
# which for something like Zika or acute flaccid myelitis is close to
# identifying. Set to FALSE only after a release-policy decision.
COLLAPSE_RARE  <- TRUE
DISTRICT_LABEL <- "Health District 3"

# What the page shows before anyone touches the dropdowns.
# Leave "" to fall back to the first item alphabetically.
DEFAULT_CONDITION <- "Campylobacteriosis"
DEFAULT_COUNTY    <- "Canyon County"

DROP_CONDITIONS <- c(
  "2019-nCoV", "Amebiasis, NOS", "Congenital hypothyroidism",
  "Encephalitis, viral or aseptic", "Foodborne Illness, NOS",
  "Influenza Outbreak", "Streptococcal toxic-shock syndrome",
  "Waterborne Illness", "Aseptic meningitis",
  "Extraordinary occurrence of illness",
  "Hemolytic uremic synd,postdiarrheal", "Influenza",
  "Multisystem Inflammatory Syndrome in Children"
)

# --- Check the inputs are where we expect ---------------------------------
for (f in c(IN_CSV, TEMPLATE)) {
  if (!file.exists(f)) {
    stop(f, " not found in ", getwd(),
         ". Put it there, or change PROJECT_DIR at the top of this script.",
         call. = FALSE)
  }
}

# --- 1. Read and clean -----------------------------------------------------
raw <- read_csv(IN_CSV, show_col_types = FALSE)

needed  <- c("Condition", "Date", "County", "County_Code")
missing <- setdiff(needed, names(raw))
if (length(missing)) {
  stop("Missing column(s) in ", IN_CSV, ": ", paste(missing, collapse = ", "),
       call. = FALSE)
}

cases <- raw %>%
  mutate(Condition = case_when(
    Condition == "Tuberculosis (2020 RVCT)" ~ "Tuberculosis",
    Condition %in% c("Salmonellosis (excl S. Typhi and S. Paratyphi)",
                     "Salmonellosis 2018 (excl paratyphoid and typhoid)",
                     "Salmonellosis - prior to 2018") ~ "Salmonellosis",
    TRUE ~ Condition
  )) %>%
  filter(!Condition %in% DROP_CONDITIONS) %>%
  mutate(Date = mdy_hm(Date), Year = year(Date)) %>%
  filter(!is.na(Year), Year %in% YEARS)

if (nrow(cases) == 0) {
  stop("No rows left after cleaning. Check the Date format in ", IN_CSV,
       " - this script expects m/d/Y H:M.", call. = FALSE)
}

# --- 2. Count by condition / county / year, filling empty cells with zero ---
counts <- cases %>%
  count(Condition, Year, County, County_Code, name = "Incidence") %>%
  rename(GEOID = County_Code) %>%
  mutate(GEOID = as.character(GEOID))

county_lookup <- distinct(counts, GEOID, County)

complete <- expand_grid(
  Condition = sort(unique(counts$Condition)),
  Year      = YEARS,
  county_lookup
) %>%
  left_join(counts, by = c("Condition", "Year", "GEOID", "County")) %>%
  mutate(Incidence = replace_na(Incidence, 0L))

# --- 3. Decide which conditions are too rare for a county breakdown --------
rare_conditions <- complete %>%
  group_by(Condition) %>%
  summarise(ever_at_threshold = any(Incidence >= THRESHOLD), .groups = "drop") %>%
  filter(!ever_at_threshold) %>%
  pull(Condition)

if (!COLLAPSE_RARE) rare_conditions <- character(0)

# County rows for the rest; district totals for the rare ones. The county
# detail for rare conditions is dropped here and never reaches the output.
by_geography <- bind_rows(
  complete %>%
    filter(!Condition %in% rare_conditions) %>%
    transmute(Condition, Geography = County, GEOID, Year, Incidence),
  complete %>%
    filter(Condition %in% rare_conditions) %>%
    group_by(Condition, Year) %>%
    summarise(Incidence = sum(Incidence), .groups = "drop") %>%
    transmute(Condition, Geography = DISTRICT_LABEL,
              GEOID = NA_character_, Year, Incidence)
)

# --- 4. Suppress before anything leaves this script ------------------------
# Value is a string: the count when >= THRESHOLD, "<5" when 1-4, "0" when none.
# Counts of 1 to 4 are never written to disk in any form.
published <- by_geography %>%
  mutate(
    Status = case_when(
      Incidence == 0        ~ "No cases reported",
      Incidence < THRESHOLD ~ paste0("Fewer than ", THRESHOLD,
                                     " cases (suppressed)"),
      TRUE                  ~ "Reported"
    ),
    Value = case_when(
      Incidence == 0        ~ "0",
      Incidence < THRESHOLD ~ paste0("<", THRESHOLD),
      TRUE                  ~ as.character(Incidence)
    ),
    YearLabel = if_else(Year == CURRENT_YR, paste0(Year, "*"),
                        as.character(Year))
  ) %>%
  select(Condition, Geography, GEOID, Year, YearLabel, Value, Status) %>%
  arrange(Condition, Geography, Year)

write_csv(published, OUT_AUDIT)

# --- 5. Assemble the payload ----------------------------------------------
series <- published %>%
  mutate(key = paste(Condition, Geography, sep = "||")) %>%
  group_by(key) %>%
  summarise(v = list(Value), .groups = "drop") %>%
  deframe()

# A default that no longer exists in the data would silently do nothing,
# so say so rather than quietly falling back.
if (nzchar(DEFAULT_CONDITION) &&
    !DEFAULT_CONDITION %in% published$Condition) {
  warning("DEFAULT_CONDITION '", DEFAULT_CONDITION,
          "' is not in the data. The page will open on the first condition.",
          call. = FALSE)
}
if (nzchar(DEFAULT_COUNTY) &&
    !DEFAULT_COUNTY %in% county_lookup$County) {
  warning("DEFAULT_COUNTY '", DEFAULT_COUNTY,
          "' is not in the data. The page will open on the first county.",
          call. = FALSE)
}

payload <- list(
  years            = I(published %>%
                         distinct(Year, YearLabel) %>%
                         arrange(Year) %>%
                         pull(YearLabel)),
  conditions       = I(sort(unique(published$Condition))),
  counties         = I(sort(county_lookup$County)),
  rare             = I(sort(rare_conditions)),
  districtLabel    = DISTRICT_LABEL,
  defaultCondition = DEFAULT_CONDITION,
  defaultCounty    = DEFAULT_COUNTY,
  rareNote         = paste0("Shown for ", DISTRICT_LABEL,
                            " as a whole. County-level counts are not published ",
                            "for conditions this uncommon."),
  footnote         = paste0("*", CURRENT_YR, " data as of ", AS_OF, ". ",
                            CURRENT_YR,
                            " data is provisional and may be subject to change."),
  series           = series
)

json <- toJSON(payload, auto_unbox = TRUE, null = "null")

# --- 6. Inject into the template ------------------------------------------
tpl   <- paste(readLines(TEMPLATE, warn = FALSE), collapse = "\n")
parts <- strsplit(tpl, "/*__DATA__*/", fixed = TRUE)[[1]]

if (length(parts) != 2) {
  stop("Could not find the /*__DATA__*/ placeholder in ", TEMPLATE,
       ". Use the original template file.", call. = FALSE)
}

writeLines(paste0(parts[1], json, parts[2]), OUT_HTML, useBytes = TRUE)

# --- 7. Report -------------------------------------------------------------
n_suppressed <- sum(grepl("suppressed", published$Status))
n_zero       <- sum(published$Status == "No cases reported")
n_reported   <- sum(published$Status == "Reported")

message("\nWrote ", normalizePath(OUT_HTML), " (",
        round(file.size(OUT_HTML) / 1024), " KB)")
message("Conditions: ", length(unique(published$Condition)),
        " (", length(rare_conditions), " shown district-wide only)")
message("Series: ", length(series))
message("Cells - reported: ", n_reported,
        " | suppressed: ", n_suppressed,
        " | no cases: ", n_zero)
message("Audit copy of published values: ", OUT_AUDIT, "\n")

if (length(rare_conditions)) {
  message("District-wide only:")
  message(paste0("  ", sort(rare_conditions), collapse = "\n"))
}

