require "test_helper"

# Seam B: the filter bar on the matrix and the reports list (ReportFilter).
# Every filter is a query parameter, so a filtered view is a link that works
# without JavaScript; filters combine with AND, and the exports take the same
# parameters. The production reports (schema/golden/production/reports.json)
# span four chips, three days and six tester versions.
class FiltersTest < ActionDispatch::IntegrationTest
  PRODUCTION = JSON.parse(ReportSchema.dir.join("golden", "production", "reports.json").read).fetch("reports")
  M3 = "xHGd4Toq7io8CSHYYFhTjZBD"
  M1_AIR_BUILD = "0052582.362956774610001"
  M1_AIR_SET = "apple-test-0052582276d9-20260927"

  setup do
    PRODUCTION.each do |entry|
      report = Report.create!(body: entry["report"].except("signature"), schema_version: entry["report"]["schema_version"],
                              machine_id: "key:machine-#{entry["id"]}", created_at: Time.iso8601(entry["uploaded_at"]))
      report.update_columns(public_id: entry["id"])
    end
  end

  def listed(params = {})
    get "/reports", params: params
    assert_response :success
    css_select("tr.report-row").map { |row| row["id"].delete_prefix("report-") }
  end

  def m2_boards = PRODUCTION.select { |e| e["report"]["machine"]["chip"].start_with?("M2") }.map { |e| e["report"]["machine"]["board"] }.uniq.sort

  def count = css_select(".filter-count").sole["data-count"].to_i

  def ids_where(&block) = PRODUCTION.select { |entry| block.call(entry["report"], entry) }.map { |entry| entry["id"] }.sort

  def parse_csv(text)
    text.split("\r\n").map { |line| line.scan(/"((?:[^"]|"")*)"/).flatten.map { |field| field.gsub('""', '"') } }
  end

  test "every run filter narrows the reports list, and the count says how many match" do
    assert_equal PRODUCTION.size, listed.size
    assert_equal PRODUCTION.size, count
    assert_select ".filter-chip", 0
    assert_select ".filter-clear", 0

    assert_equal ids_where { |r| r["machine"]["chip"] == "M1 Pro" }, listed(chip: "M1 Pro").sort
    assert_equal 4, count
    assert_equal ids_where { |r| r["machine"]["chip"].start_with?("M1") }, listed(gen: "m1").sort
    assert_equal 6, count
    assert_equal ids_where { |r| r["machine"]["soc"] == "t6021" }, listed(soc: "t6021").sort
    assert_equal ids_where { |r| r["machine"]["board"] == "j613" }, listed(model: "j613").sort
    assert_equal [ M3 ], listed(gen: "M3")
    assert_equal ids_where { |r| r["tool"]["version"] == "0.1.8" }, listed(tool: "0.1.8").sort
    assert_equal 4, count
    assert_equal ids_where { |r| r["system"]["stack"] == "converged" }, listed(stack: "converged").sort
    assert_equal [], listed(stack: "mx-mac")
    assert_equal PRODUCTION.size, listed(release: "4.0.0").size
    assert_equal [], listed(release: "4.1.0")
    assert_select ".dim", /No reports match these filters yet/
    assert_equal ids_where { |r| Report.new(body: r).build&.id == M1_AIR_BUILD }, listed(build: M1_AIR_BUILD).sort
    assert_equal listed(build: M1_AIR_BUILD).sort, listed(set: M1_AIR_SET).sort
    assert_equal 4, count
  end

  test "the upload date range takes whole UTC days, each end included" do
    assert_equal ids_where { |_, e| e["uploaded_at"].start_with?("2026-09-27") }, listed(from: "2026-09-27", to: "2026-09-27").sort
    assert_equal 7, count
    assert_equal [ M3 ], listed(from: "2026-09-28")
    assert_equal ids_where { |_, e| e["uploaded_at"] < "2026-09-27" }, listed(to: "2026-09-26").sort
    # A malformed date is dropped, not an error.
    assert_equal PRODUCTION.size, listed(from: "yesterday", to: "2026-02-31").size
    assert_select ".filter-chip", 0
  end

  test "tester runs only, or community runs only" do
    Tester.find_or_create_by!(login: "maralcbr")
    Report.where(public_id: [ M3, PRODUCTION.find { |e| e["id"].start_with?("Gbu7hc") }["id"] ]).update_all(tester_login: "maralcbr")

    assert_equal 2, listed(runs: "tester").size
    assert_select "tr.report-row .badge-tester", 2
    assert_equal PRODUCTION.size - 2, listed(runs: "community").size
    assert_select "tr.report-row .badge-tester", 0
    assert_equal PRODUCTION.size, listed(runs: "all").size
  end

  test "feature filters keep the catalogue and narrow the result boxes by model and build" do
    params = { model: "j313", build: M1_AIR_BUILD }
    expected = ids_where { |report| report["machine"]["board"] == "j313" && Report.new(body: report).build&.matches?(M1_AIR_BUILD) }

    get "/features", params: params
    assert_response :success
    assert_equal expected.size, count
    assert_equal %w[model build], css_select("form.filter-bar select").map { |select| select["name"] }
    assert_select "form.filter-bar input", 0
    assert_select "tr.feature-row", Catalogue.features.size
    boxes = css_select(".feature-result")
    assert boxes.any?
    assert_equal [ "j313" ], boxes.map { |box| box["data-board"] }.uniq
    assert_equal [ M1_AIR_BUILD ], boxes.map { |box| box["data-build"] }.uniq
    assert_select ".filter-chip[data-filter=model][href=?]", "/features?build=#{M1_AIR_BUILD}"
    assert_select ".filter-chip[data-filter=build][href=?]", "/features?model=j313"
    assert_select ".filter-clear[href=?]", "/features"
    assert_select "tr#feature-gpu td:first-child a[href=?]", "/features/gpu?build=#{M1_AIR_BUILD}&model=j313"

    get "/features/gpu", params: params
    assert_response :success
    rows = css_select("tr.result-row")
    assert rows.any?
    assert_equal [ "j313" ], rows.map { |row| row["data-board"] }.uniq
    assert_equal [ M1_AIR_BUILD ], rows.map { |row| row["data-build"] }.uniq
    assert_select ".filter-chip[data-filter=build][href=?]", "/features/gpu?model=j313"
    assert_select "select[name=model] option[value=j313][selected]"
  end

  test "feature build choices follow the model and distinguish variants of one runtime" do
    get "/features", params: { model: "j416c" }
    assert_response :success
    builds = Report.visible.select { |report| report.board == "j416c" }.filter_map(&:build).uniq(&:words)
    options = css_select("select[name=build] option").reject { |option| option["value"].blank? }
    assert_equal builds.map(&:words).sort, options.map { |option| option["value"] }.sort
    assert_select "select[name=model] option[value=j313]", 1, "the model picker still allows other models"
    variants = builds.group_by(&:label).values.find { |group| group.size > 1 }
    assert variants, "the fixtures include multiple kernels on one runtime"
    variants.each do |build|
      assert_select "select[name=build] option[value=?]", build.words, /#{Regexp.escape(build.words)}/
    end
  end

  test "unknown feature filters show no results without hiding the catalogue" do
    get "/features", params: { model: "unknown-model", build: "unknown-build" }
    assert_response :success
    assert_equal 0, count
    assert_select "tr.feature-row", Catalogue.features.size
    assert_select ".feature-result", 0
    assert_select "select[name=model] option[value=unknown-model][selected]"
    assert_select "select[name=build] option[value=unknown-build][selected]"
    assert_select ".dim", /No reports match these filters yet/
  end

  test "the running kernel filter narrows pages and exports and keeps unknown choices" do
    kernel = "7.1.12-2-11-ARCH"
    expected = ids_where { |report| report["machine"]["kernel"] == kernel }
    assert_equal expected, listed(kernel:).sort
    assert_select "select[name=kernel] option[selected][value=?]", kernel
    assert_select ".filter-chip[data-filter=kernel]", "kernel: #{kernel} ×"

    get "/matrix", params: { group: "build", kernel: }
    assert_equal expected.size, count
    get "/api/v1/reports.json", params: { kernel: }
    assert_equal({ "kernel" => kernel }, response.parsed_body["filters"])
    assert_equal expected, response.parsed_body["reports"].map { |report| report["id"] }.sort
    get "/api/v1/checks.csv", params: { kernel: }
    assert_equal expected, parse_csv(response.body).drop(1).map(&:first).uniq.sort
    get "/api/v1/matrix.json", params: { kernel: }
    assert_equal expected.size, response.parsed_body["runs"]

    assert_equal [], listed(kernel: "unknown-kernel")
    assert_select "select[name=kernel] option[selected][value=unknown-kernel]"
  end

  test "kernel choices sort version numbers naturally and use the running kernel" do
    report = Report.first.body.deep_dup
    report["machine"]["kernel"] = "7.1.12-2-100-ARCH"
    Report.create!(body: report, schema_version: report["schema_version"])
    listed
    choices = css_select("select[name=kernel] option").map { |option| option["value"] }.reject(&:empty?)
    assert_equal "7.1.12-2-100-ARCH", choices.first
    assert choices.index("7.1.12-2-11-ARCH") < choices.index("7.1.12-2-10-ARCH")
    assert_equal [ "7.1.12-2-100-ARCH" ], listed(kernel: "7.1.12-2-100-ARCH").map { |id| Report.find_by!(public_id: id).kernel }
  end

  test "filters combine with AND, show as removable chips, and clear goes back to everything" do
    ids = listed(gen: "m1", tool: "0.1.8", from: "2026-09-27")
    assert_equal ids_where { |r, e| r["machine"]["chip"].start_with?("M1") && r["tool"]["version"] == "0.1.8" && e["uploaded_at"] >= "2026-09-27" }, ids.sort
    assert_equal 2, count
    chips = css_select(".filter-chip").to_h { |chip| [ chip["data-filter"], chip ] }
    assert_equal %w[gen tool from], chips.keys
    assert_match "generation: M1", chips["gen"].text
    assert_match "tester version: 0.1.8", chips["tool"].text
    # Each chip links to the same view without it.
    assert_equal "/reports?from=2026-09-27&tool=0.1.8", chips["gen"]["href"]
    assert_select ".filter-clear[href=?]", "/reports"
    # The form shows what's picked, so submitting it again keeps the filters.
    assert_select %(form.filter-bar[method="get"][action="/reports"])
    assert_select %(select[name="gen"] option[selected][value="m1"])
    assert_select %(select[name="tool"] option[selected][value="0.1.8"])
    assert_select %(input[name="from"][value="2026-09-27"])
    # A filter that matches nothing keeps its chip, with none of the runs.
    assert_equal [], listed(gen: "m1", chip: "M2 Max")
    assert_equal 0, count
  end

  test "a build filter as long as an image's build words is kept" do
    long = "apple-test-1937418f520b-20260926 (#{"x" * 400})"
    assert_equal [], listed(build: long)
    assert_select %(.filter-chip[data-filter="build"])
  end

  test "an unknown value matches nothing, and a value past the choices still shows as picked" do
    assert_equal [], listed(model: "j999")
    assert_select %(select[name="model"] option[selected][value="j999"])
    assert_equal [], listed(tool: "9.9.9")
    # Values that aren't a choice are dropped: the view is unfiltered.
    assert_equal PRODUCTION.size, listed(stack: "bogus", runs: "someone", gen: "m9", confirmed: "yes").size
    assert_select ".filter-chip", 0
  end

  test "confirmed only leaves the answers given by a bare Enter out of the counts" do
    m3 = PRODUCTION.find { |entry| entry["id"] == M3 }["report"]
    by_default = m3["checks"].count { |check| check["answered_by_default"] }
    assert by_default.positive?

    listed
    all = css_select("tr#report-#{M3} td.nowrap").last.text[/(\d+) pass/, 1].to_i
    assert_equal PRODUCTION.size, listed(confirmed: "1").size
    assert_select %(.filter-chip[data-filter="confirmed"]), /results: confirmed only/
    confirmed = css_select("tr#report-#{M3} td.nowrap").last.text[/(\d+) pass/, 1].to_i
    assert_equal by_default, all - confirmed
  end

  test "the matrix takes every run filter, with the count of runs behind it" do
    get "/matrix", params: { group: "build", gen: "m1" }
    assert_equal 6, count
    m1_boards = PRODUCTION.select { |e| e["report"]["machine"]["chip"].start_with?("M1") }.map { |e| e["report"]["machine"]["board"] }.uniq.sort
    assert_equal m1_boards, css_select("tr.matrix-row").map { |row| row["data-board"] }.uniq.sort

    get "/matrix", params: { group: "build", chip: "M3", tool: "0.1.8", to: "2026-09-28" }
    assert_equal [ "j613" ], css_select("tr.matrix-row").map { |row| row["data-board"] }
    assert_equal 1, count

    # The count is of the runs behind the rows shown: result filters leave rows out.
    get "/matrix", params: { group: "build", gen: "m1", state: "regression" }
    assert_select "tr.matrix-row", 0
    assert_equal 0, count
    get "/matrix", params: { group: "build", confirmed: "1" }
    assert_equal css_select("tr.matrix-row .row-meta").sum { |meta| meta.text[/(\d+) reports?/, 1].to_i }, count
    assert count < PRODUCTION.size

    get "/matrix", params: { group: "build", from: "2026-09-29" }
    assert_select "tr.matrix-row", 0
    assert_select ".card .dim", /No reports match these filters yet/
  end

  test "the matrix's layer filter keeps one layer's columns" do
    get "/matrix", params: { group: "build", layer: "aurora" }
    layers = css_select("th.feature-head").map { |th| th["class"][/layer-(\w+)/, 1] }.uniq
    assert_equal [ "aurora" ], layers
    assert_equal Catalogue.tested_features.count { |f| f["layer"] == "aurora" }, css_select("th.feature-head").size
    assert_select %(.filter-chip[data-filter="layer"]), /layer: Aurora addition/
  end

  test "the matrix's state filter keeps the rows and columns with a cell in that state" do
    %w[works fails gap untested].each do |state|
      get "/matrix", params: { group: "build", state: }
      wanted = ReportFilter::STATES.fetch(state)
      rows = css_select("tr.matrix-row")
      rows.each do |row|
        displayed = row.css("td[data-feature]").map { |td| td["class"][/cell-hint-([\w-]+)/, 1] || td["data-state"] }
        assert (displayed & wanted).any?, "every #{state} row has a #{state} cell"
      end
      columns = css_select("th.feature-head").size
      css_select("th.feature-head").each_with_index do |_, index|
        column = rows.map { |row| row.css("td[data-feature]")[index] }
        assert column.any? { |td| wanted.include?(td["class"][/cell-hint-([\w-]+)/, 1] || td["data-state"]) }, "every #{state} column has a #{state} cell"
      end
      assert columns <= Catalogue.tested_features.size
    end
  end

  test "confirmed only hides the matrix cells community machines don't agree on" do
    get "/matrix", params: { group: "build" }
    all = css_select("tr.matrix-row").size
    assert css_select(%(td[data-state="unconfirmed"])).any?, "most production runs are the only machine on their build: unconfirmed"
    assert_includes css_select("tr.matrix-row").map { |row| row["data-board"] }, "j613"

    get "/matrix", params: { group: "build", confirmed: "1" }
    assert_select %(td[data-state="unconfirmed"]), 0
    assert css_select(%(td[data-state="hidden"].cell-hidden)).any?
    rows = css_select("tr.matrix-row")
    assert rows.size < all
    rows.each { |row| assert row.css("td[data-feature]").any? { |td| !%w[hidden not-tested].include?(td["data-state"]) } }
    # The M3 is the only machine on its build: nothing it found is confirmed.
    assert_not_includes rows.map { |row| row["data-board"] }, "j613"

    # A tester run colours cells on its own, so its row comes back.
    Tester.find_or_create_by!(login: "maralcbr")
    Report.find_by!(public_id: M3).update_columns(tester_login: "maralcbr")
    get "/matrix", params: { group: "build", confirmed: "1" }
    assert css_select(%(tr.matrix-row[data-board="j613"] td[data-verified="tester"])).any?
  end

  test "the old matrix and reports links keep working, and keep the other filters" do
    get "/matrix", params: { group: "build", build: M1_AIR_BUILD }
    assert_equal [ M1_AIR_BUILD ], css_select("tr.matrix-row").map { |row| row["data-build"] }.uniq
    assert_select %(.filter-chip[data-filter="build"])

    get "/matrix", params: { group: "release", gen: "m2" }
    assert_equal [ "" ], css_select("tr.matrix-row").map { |row| row["data-build"].to_s }.uniq
    assert_equal m2_boards, css_select("tr.matrix-row").map { |row| row["data-board"] }.uniq.sort
    # group stays through the form, the chips and clear.
    assert_select %(form.filter-bar input[type="hidden"][name="group"][value="release"])
    assert_select ".filter-chip[href=?]", "/matrix?group=release"
    assert_select ".filter-clear[href=?]", "/matrix?group=release"
    # Changing the grouping keeps the other filters.
    assert_select ".matrix-view-switch a[href=?]", "/matrix?gen=m2&group=build", "Build"
    assert_select ".matrix-view-switch a[href=?]", "/matrix?gen=m2&group=model", "Model"
    assert_select ".matrix-view-switch a[aria-current=page]", "Release"

    assert_equal ids_where { |r| Report.new(body: r).build&.id == M1_AIR_BUILD }, listed(build: M1_AIR_BUILD).sort
  end

  test "the reports exports take the filters, and without any are unchanged" do
    get "/api/v1/reports.json"
    body = response.parsed_body
    assert_equal %w[license note generated_at catalogue_version reports], body.keys
    assert_equal PRODUCTION.size, body["reports"].size

    get "/api/v1/reports.json", params: { gen: "m1", tool: "0.1.8" }
    body = response.parsed_body
    assert_equal({ "gen" => "m1", "tool" => "0.1.8" }, body["filters"])
    assert_equal ids_where { |r| r["machine"]["chip"].start_with?("M1") && r["tool"]["version"] == "0.1.8" }, body["reports"].map { |r| r["id"] }.sort

    get "/api/v1/reports.csv", params: { chip: "M2 Max", from: "2026-09-27" }
    rows = parse_csv(response.body)
    assert_equal DataExport::REPORT_COLUMNS, rows.first
    assert_equal ids_where { |r, e| r["machine"]["chip"] == "M2 Max" && e["uploaded_at"] >= "2026-09-27" }, rows.drop(1).map(&:first).sort

    # Confirmed only counts the checks without those answered by a bare Enter.
    m3 = PRODUCTION.find { |entry| entry["id"] == M3 }["report"]
    get "/api/v1/reports.csv", params: { model: "j613", confirmed: "1" }
    row = parse_csv(response.body).drop(1).sole
    assert_equal (m3["checks"].size - m3["checks"].count { |c| c["answered_by_default"] }).to_s, row[DataExport::REPORT_COLUMNS.index("checks")]
  end

  test "checks.csv takes the run filters and the result filters" do
    get "/api/v1/checks.csv"
    all = parse_csv(response.body).drop(1)
    column = ->(name) { DataExport::CHECK_COLUMNS.index(name) }

    get "/api/v1/checks.csv", params: { model: "j613" }
    m3 = parse_csv(response.body).drop(1)
    assert_equal all.select { |row| row[column["board"]] == "j613" }, m3

    get "/api/v1/checks.csv", params: { model: "j613", layer: "aurora" }
    assert_equal m3.select { |row| row[column["layer"]] == "aurora" }, parse_csv(response.body).drop(1)

    get "/api/v1/checks.csv", params: { model: "j613", confirmed: "1" }
    assert_equal m3.reject { |row| row[column["answered_by_default"]] == "true" }, parse_csv(response.body).drop(1)

    get "/api/v1/checks.csv", params: { model: "j613", state: "gap" }
    gaps = parse_csv(response.body).drop(1)
    assert gaps.any?
    assert(gaps.all? { |row| %w[not-in-aurora not-in-asahi not-in-omarchy].include?(row[column["outcome"]]) })

    get "/api/v1/checks.csv", params: { model: "j613", state: "works", layer: "omarchy", confirmed: "1" }
    rows = parse_csv(response.body).drop(1)
    assert(rows.all? { |row| row[column["outcome"]] == "works" && row[column["layer"]] == "omarchy" && row[column["answered_by_default"]] == "false" })
  end

  test "matrix.json takes the filters and ?group=release, and without any is unchanged" do
    get "/api/v1/matrix.json"
    plain = response.parsed_body
    assert_equal %w[license generated_at catalogue_version agreement features rows], plain.keys
    assert_equal Catalogue.tested_features.size, plain["features"].size

    get "/api/v1/matrix.json", params: { gen: "m2", layer: "asahi" }
    body = response.parsed_body
    assert_equal({ "gen" => "m2", "layer" => "asahi" }, body["filters"])
    assert_equal 4, body["runs"]
    assert_equal m2_boards, body["rows"].map { |row| row["board"] }.uniq.sort
    assert_equal [ "asahi" ], body["features"].map { |f| f["layer"] }.uniq
    assert_equal body["features"].map { |f| f["id"] }.sort, body["rows"].first["cells"].keys.sort

    get "/api/v1/matrix.json", params: { gen: "m2", group: "release" }
    assert_equal m2_boards.size, response.parsed_body["rows"].size

    get "/api/v1/matrix.json", params: { confirmed: "1" }
    cells = response.parsed_body["rows"].flat_map { |row| row["cells"].values }
    assert(cells.none? { |cell| cell["state"].nil? && !cell["hidden"] })
    assert(cells.any? { |cell| cell["hidden"] })
  end

  test "the pages link the exports with the same filters" do
    get "/reports", params: { gen: "m1" }
    assert_select ".filter-exports a[href=?]", "/api/v1/reports.json?gen=m1"
    assert_select ".filter-exports a[href=?]", "/api/v1/reports.csv?gen=m1"
    assert_select ".filter-exports a[href=?]", "/api/v1/checks.csv?gen=m1"

    get "/matrix", params: { gen: "m1", layer: "aurora", group: "release" }
    assert_select ".filter-exports a[href=?]", "/api/v1/matrix.json?gen=m1&group=release&layer=aurora"
    assert_select ".filter-exports a[href=?]", "/api/v1/checks.csv?gen=m1&layer=aurora"
  end
end
