require "test_helper"

# Seam B: the build view and its aggregation rules. Community
# reports show up right away but colour a cell only once two or more distinct
# machines agree.
class MatrixTest < ActionDispatch::IntegrationTest
  M2 = { board: "j416c", stack: "converged", version: "4.0.0" }.freeze
  M1 = { board: "j314s", stack: "mx-mac", version: "4.0.2" }.freeze

  def cell(row, feature)
    css_select(%(tr.matrix-row[data-board="#{row[:board]}"][data-stack="#{row[:stack]}"][data-version="#{row[:version]}"] td[data-feature="#{feature}"])).sole
  end

  def state(row, feature) = cell(row, feature)["data-state"]

  test "a single community report is listed but leaves the matrix unconfirmed" do
    upload_report golden("m2-max-image2")

    get "/matrix", params: { group: "build" }
    assert_response :success
    assert_equal "unconfirmed", state(M2, "gpu")
    assert_includes cell(M2, "gpu")["class"], "cell-unconfirmed cell-hint-works"
    assert_match "community, unconfirmed: 1 machine works", cell(M2, "gpu")["title"]
    assert_select "tr.matrix-row .row-meta", "converged 4.0.0 · 1 report"

    get "/reports"
    assert_select "tr.report-row .badge-community", "community"
  end

  test "two reports from the same machine don't confirm each other" do
    2.times { upload_report golden("m2-max-image2"), machine: "a" }

    get "/matrix", params: { group: "build" }
    assert_equal "unconfirmed", state(M2, "gpu")
    assert_select "tr.matrix-row .row-meta", "converged 4.0.0 · 2 reports"
  end

  test "two distinct machines agreeing colour the cell" do
    upload_report golden("m2-max-image2"), machine: "a"
    upload_report golden("m2-max-image2"), machine: "b"

    get "/matrix", params: { group: "build" }
    assert_equal "works", state(M2, "gpu")
    assert_includes cell(M2, "gpu")["class"], "cell-works"
    assert_equal "works: 2 machines works", cell(M2, "gpu")["title"]
    # packages.hardware passes and setup.first-boot-hardware fails: partial on both machines
    assert_equal "partial", state(M2, "first-boot-hardware-setup")
    # gpu.opengl is skipped, but gpu.driver and gpu.vulkan work
    assert_select %(td[data-feature="gpu"] a[href^="/reports/"])
  end

  test "agreeing failures are orange, missing support blue and unknown hardware magenta" do
    outcomes = { "display.backlight" => "fails", "input.ambient-light" => "not-in-aurora", "power.battery" => "unknown-hardware",
                 "network.bluetooth" => "not-applicable" }
    upload_report golden_with("m2-max-image2", outcomes), machine: "a"
    upload_report golden_with("m2-max-image2", outcomes), machine: "b"

    get "/matrix", params: { group: "build" }
    assert_equal "fails", state(M2, "brightness")
    assert_equal "missing", state(M2, "aop")
    assert_equal "unknown", state(M2, "battery-info")
    assert_equal "not-applicable", state(M2, "bluetooth")
    assert_select ".legend li", /regression/
    assert_select ".legend li", /doesn't work/
    assert_select ".legend li", /expected missing/
    assert_select ".legend li", /unknown hardware/
  end

  test "machines that disagree leave the cell unconfirmed, until each side has two machines: partial" do
    upload_report golden("m2-max-image2"), machine: "a"
    upload_report golden_with("m2-max-image2", "display.backlight" => "fails"), machine: "b"

    get "/matrix", params: { group: "build" }
    assert_equal "unconfirmed", state(M2, "brightness")
    assert_match "1 machine works, 1 machine doesn't work", cell(M2, "brightness")["title"]
    assert_includes cell(M2, "brightness")["class"], "cell-hint-partial", "a tie hints partial, not the better state"

    upload_report golden("m2-max-image2"), machine: "c"
    get "/matrix", params: { group: "build" }
    assert_equal "works", state(M2, "brightness")

    upload_report golden_with("m2-max-image2", "display.backlight" => "fails"), machine: "d"
    get "/matrix", params: { group: "build" }
    assert_equal "partial", state(M2, "brightness")
  end

  test "each machine counts with the latest state it tested" do
    upload_report golden_with("m2-max-image2", "display.backlight" => "fails"), machine: "a"
    upload_report golden("m2-max-image2"), machine: "a"
    upload_report golden_with("m2-max-image2", "display.backlight" => "not-tested"), machine: "a"
    upload_report golden("m2-max-image2"), machine: "b"

    get "/matrix", params: { group: "build" }
    assert_equal "works", state(M2, "brightness")
  end

  test "features no machine tested are grey" do
    upload_report golden("m1-pro-mx-mac"), machine: "a"
    upload_report golden("m1-pro-mx-mac"), machine: "b"

    get "/matrix", params: { group: "build" }
    assert_equal "not-tested", state(M1, "dcp")
    assert_equal "fails", state(M1, "vendor-firmware")
  end

  test "rows are per model and stack/version, and the stack filter narrows them" do
    upload_report golden("m2-max-image2")
    upload_report golden("m1-pro-mx-mac")
    newer = golden("m2-max-image2").tap { |r| r["system"]["packages"][0]["version"] = "4.1.0-1" }
    upload_report newer

    get "/matrix", params: { group: "build" }
    assert_select "tr.matrix-row", 3
    assert_select %(tr.matrix-row[data-board="j416c"]), 2
    assert_equal [ "4.1.0", "4.0.0" ], css_select(%(tr.matrix-row[data-board="j416c"])).map { |row| row["data-version"] }
    assert_select "th.feature-head", Catalogue.tested_features.size

    get "/matrix", params: { group: "build", stack: "mx-mac" }
    assert_select "tr.matrix-row", 1
    assert_select %(tr.matrix-row[data-board="j314s"][data-stack="mx-mac"])
    assert_select %(select[name="stack"] option[selected]), "mx-mac"
    assert_select %(.filter-chip[data-filter="stack"]), /stack: mx-mac/
  end

  test "the home page shows the matrix, or says there are no reports yet" do
    get "/"
    assert_select ".card", /No reports yet/

    upload_report golden("m2-max-image2")
    get "/"
    assert_select "table.matrix tr.model-summary", 1
    assert_select "tbody.matrix-history tr.build-row", 1
  end

  test "reports uploaded before machine ids existed count as one machine" do
    2.times { upload_report golden("m2-max-image2") }
    Report.update_all(machine_id: nil)

    get "/matrix", params: { group: "build" }
    assert_equal "unconfirmed", state(M2, "gpu")
  end
end
