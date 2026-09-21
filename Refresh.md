# Monthly refresh

How to update the published chart at
https://southwest-district-health.github.io/reportable-disease-counts/

Takes about 10 minutes. Anyone with access to the case export and write
access to this repo can do it.

---

## 1. Export the case data

Pull the reportable disease export and save it as `Case_data.csv` in
`Documents\R\Cases_Dashboard`, replacing the previous file.

The script expects these columns: `Condition`, `Date`, `County`,
`County_Code`. Dates in m/d/Y H:M format. If the export format changes, the
script stops with a message naming the problem rather than publishing
something wrong.

## 2. Keep a copy of last month's output

Before rebuilding, rename the existing `published_data.csv` to
`published_data_YYYYMM.csv` using last month's date. This gives you a record
of what was public at each point, which is useful for records requests and
for the check in step 5.

## 3. Update the date settings

Open `build_chart.R` and edit:

- `AS_OF` — the through date of this export, e.g. `"07/31/2026"`.
  This is the only date the public sees. Easy to forget, and a stale one
  misrepresents how current the data is.

In January, also update:

- `CURRENT_YR` — the new year, which gets the asterisk and the provisional note
- `YEARS` — extend the range, e.g. `2018:2027`

## 4. Run it

```r
source("build_chart.R", echo = TRUE)
```

Read the console output. It reports the file size, how many conditions are
shown district-wide only, the reported / suppressed / no-case cell counts,
and the full list of collapsed conditions.

## 5. Check before publishing

Confirm no small counts leaked:

```r
published %>% count(Value) %>% filter(!Value %in% c("0", "<5"))
```

Every value returned should be 5 or higher.

Compare against last month:

```r
prev <- readr::read_csv("published_data_YYYYMM.csv", show_col_types = FALSE)

dplyr::anti_join(published, prev,
                 by = c("Condition", "Geography", "Year")) %>%
  dplyr::count(Condition, sort = TRUE)
```

Changes should be concentrated in the current year. A condition changing in
earlier years means a data correction upstream, which is worth understanding
before it goes public.

Watch for conditions moving between county-level and district-wide. A
condition that crosses the threshold for the first time gains a county
breakdown, which is expected, but check it reads sensibly.

Then open `index.html` locally and click through a few conditions.

## 6. Publish

Upload the new `index.html` to this repo (Add file, then Upload files).
Commit message: `Data refresh through MM/DD/YYYY`.

GitHub Pages redeploys in a minute or two. Hard refresh the live URL with
Ctrl+F5 to get past the browser cache and confirm the footnote shows the new
`AS_OF` date.

Do not commit `Case_data.csv` or any other case-level file. The `.gitignore`
blocks CSVs, but the web uploader is less reliable about honoring it than
git is, so check the file list before committing.

---

## Notes

- `published_data.csv` contains only suppressed values and is safe to share.
- `Case_data.csv` is case-level and never leaves the project folder.
- Suppression threshold and the district-wide collapse rule are set at the
  top of `build_chart.R`. Changing either is a data release policy decision,
  not a technical one.
