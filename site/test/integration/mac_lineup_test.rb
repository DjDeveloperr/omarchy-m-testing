require "test_helper"

# The bring-up table on /models: every Mac, tested or not, with its GPU and display bring-up state.
class MacLineupTest < ActionDispatch::IntegrationTest
  def lineup_row(board) = css_select(%(tr.lineup-row[data-boards~="#{board}"])).sole
  def status(board, area) = lineup_row(board).css(%(td.lineup-status[data-area="#{area}"])).sole

  test "untested Macs show and ask for testing" do
    get "/models"
    assert_response :success
    assert_select "tr.lineup-row", MacLineup.models.size
    assert_equal "false", lineup_row("j504")["data-tested"]
    assert_match "needs testing", lineup_row("j504").css(%(td.lineup-testing div[data-board="j504"])).text
  end

  test "a hand-kept bring-up note wins over the catalogue" do
    get "/models"
    gpu = status("j514c", "gpu")
    assert_equal [ "missing", "curated" ], [ gpu["data-status"], gpu["data-source"] ]
    assert_match "the kernel GPU only matches the J516C", gpu.text
    assert_equal "pending", status("j516c", "gpu")["data-status"]
  end

  test "without a note the catalogue's expected Asahi and Aurora states decide" do
    get "/models"
    gpu = status("j416c", "gpu")
    assert_equal [ "works", "catalogue" ], [ gpu["data-status"], gpu["data-source"] ]
    assert_equal "missing", status("j700", "gpu")["data-status"]
    assert_equal "works", status("j413", "display")["data-status"]
    assert_equal "missing", status("j700", "display")["data-status"]
  end

  test "a tested board shows its runs and what they found" do
    upload_report golden("m2-max-image2")

    get "/models"
    row = lineup_row("j416c")
    assert_equal "true", row["data-tested"]
    assert_match "1 run", row.css(%(td.lineup-testing div[data-board="j416c"])).text
    assert_equal "works", row.css(%(td[data-area="gpu"] .lineup-tested[data-board="j416c"])).sole["data-state"]
    assert_match "needs testing", row.css(%(td.lineup-testing div[data-board="j414c"])).text
  end
end
