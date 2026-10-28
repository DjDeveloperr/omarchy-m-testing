require "test_helper"

# Seam B: a human check answered yes by a bare Enter (answered_by_default) is
# shown as "works (unconfirmed)" and never colours the matrix or counts for a
# tester; a typed yes counts as before.
class AnsweredByDefaultTest < ActionDispatch::IntegrationTest
  M2 = "j416c".freeze
  CHECK = "input.trackpad-gestures".freeze  # the only check of the touchpad feature

  setup { Tester.create!(login: "tester-one") }

  def trackpad_yes(by_default:)
    golden_with("m2-max-image2", CHECK => "works").tap do |report|
      check = report["checks"].find { |c| c["id"] == CHECK }
      check["answered_by_default"] = true if by_default
    end
  end

  def touchpad_cell
    get "/matrix"
    css_select(%(tr.model-summary[data-board="#{M2}"] td[data-feature="touchpad"])).sole
  end

  test "the report is accepted and its check shows as works (unconfirmed)" do
    body = upload_report(trackpad_yes(by_default: true))
    assert_response :created

    get path_of(body.fetch("report_url"))
    badge = css_select(%(li[id="check-#{CHECK}"] .answered-by-default)).sole
    assert_equal "works (unconfirmed)", badge.text
    assert_includes badge["class"], "badge-unconfirmed"
    assert_select %(li[id="check-#{CHECK}"] .badge-works), 0
  end

  test "Enter-only yeses from two machines don't colour the matrix; typed ones do" do
    upload_report trackpad_yes(by_default: true), machine: "a"
    upload_report trackpad_yes(by_default: true), machine: "b"
    assert_equal "not-tested", touchpad_cell["data-state"]

    upload_report trackpad_yes(by_default: false), machine: "c"
    upload_report trackpad_yes(by_default: false), machine: "d"
    assert_equal "works", touchpad_cell["data-state"]
  end

  test "a tester's Enter-only yes isn't tester-verified; a typed yes is" do
    bind_machine "a", "tester-one"
    upload_report trackpad_yes(by_default: true), machine: "a"
    cell = touchpad_cell
    assert_equal "not-tested", cell["data-state"]
    assert_nil cell["data-verified"]

    upload_report trackpad_yes(by_default: false), machine: "a"
    cell = touchpad_cell
    assert_equal "works", cell["data-state"]
    assert_equal "tester", cell["data-verified"]
  end

  test "a candidate set whose tester runs counted nothing is still waiting, not ready" do
    bind_machine "a", "tester-one"
    report = golden("m2-max-image2").tap do |r|
      r["system"]["candidate_set"] = "edge-2026.09.27"
      r["checks"].each { |check| check["answered_by_default"] = true }
    end
    upload_report report, machine: "a"
    assert_response :created

    get "/candidates/edge-2026.09.27"
    assert_response :success
    assert_match "Waiting for tester runs", response.body
    assert_no_match "Ready for promotion", response.body
  end

  test "a report without the field counts as before, and checks.csv says which answers were the default" do
    upload_report trackpad_yes(by_default: true), machine: "a"
    upload_report golden("m2-max-image2"), machine: "b"
    assert_response :created

    get "/api/v1/checks.csv"
    rows = response.body.split("\r\n").map { |line| line.scan(/"((?:[^"]|"")*)"/).flatten }
    assert_includes rows[0], "answered_by_default"
    trackpad = rows.drop(1).map { |row| rows[0].zip(row).to_h }.select { |row| row["check_id"] == CHECK }
    assert_equal %w[false true], trackpad.map { |row| row["answered_by_default"] }.sort
  end

  test "the schema only allows true" do
    report = trackpad_yes(by_default: false)
    report["checks"].find { |c| c["id"] == CHECK }["answered_by_default"] = false
    assert_not_empty ReportSchema.errors(report)
  end
end
