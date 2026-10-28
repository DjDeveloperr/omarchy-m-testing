require "test_helper"

# Seam B: which build each run is on, everywhere versions appear. The
# production reports (schema/golden/production/reports.json, the site's public
# export) are stored as the site holds them, uploaded under older tool
# versions; schema/golden/production/builds.json is the build the CLI derives
# for each (cli/tests/test_build_identity.py reads the same file).
class BuildIdentityTest < ActionDispatch::IntegrationTest
  PRODUCTION = JSON.parse(ReportSchema.dir.join("golden", "production", "reports.json").read).fetch("reports")
  GOLDEN_BUILDS = JSON.parse(ReportSchema.dir.join("golden", "production", "builds.json").read)
  BUILDS = GOLDEN_BUILDS.fetch("builds")
  M3 = "xHGd4Toq7io8CSHYYFhTjZBD"
  M3_BUILD = "f60e1ba.2026092602"
  M1_AIR_BUILD = "0052582.362956774610001"

  # The production reports as the site stores them, oldest first; public ids kept so the golden builds line up.
  def store_production
    PRODUCTION.each_with_index do |entry, index|
      report = Report.create!(body: entry["report"].except("signature"), schema_version: entry["report"]["schema_version"],
                              machine_id: "key:machine-#{entry["id"]}", created_at: Time.iso8601(entry["uploaded_at"]))
      report.update_columns(public_id: entry["id"])
    end
  end

  def report_row(id) = css_select("tr#report-#{id}").sole

  test "every old report shows the build it was on, as the CLI derives it" do
    store_production

    get "/reports"
    assert_response :success
    BUILDS.each do |id, build|
      assert_select report_row(id), "td.build-cell[data-build=?]", build["build"]
      assert_select report_row(id), "td.build-cell a.build-id[title=?]", build["words"]
      assert_equal build["words"], Report.find_by!(public_id: id).build.words
    end
    # Every one of them is "converged 4.0.0" by its release number.
    assert_equal [ "converged 4.0.0" ], css_select("tr.report-row td:nth-child(3)").map(&:text).uniq

    get "/reports", params: { build: M3_BUILD }
    assert_equal [ "report-#{M3}" ], css_select("tr.report-row").map { |row| row["id"] }
  end

  test "other package sets and image records are worded as the CLI words them" do
    GOLDEN_BUILDS.fetch("examples").each do |example|
      image = example.slice("built", "package_set_sha256")
      build = Build.new(example["packages"], candidate_set: example["candidate_set"], image:)
      assert_equal example["words"], build.words, example["why"]
    end
  end

  test "the report page header names the build, its kernel, boot package and tester, with every package" do
    store_production

    get "/reports/#{M3}"
    assert_response :success
    assert_select "dd#build .build-id", M3_BUILD
    assert_select "dd#build", /linux-aurora 7\.1\.12\.aurora2-11 · omarchy-mac-boot 20260926-1 · tester 0\.1\.8/
    assert_select "details#packages[open] tr", 13
    assert_select "details#packages tr td", "4.0.0.alpha.quattro.r1790450903.gf60e1ba4c476-1.2026092602"
    # No image record in these reports.
    assert_select "dd#image", 0
  end

  test "the M3's GPU failures read as not yet supported, not as failures" do
    store_production

    get "/reports/#{M3}"
    %w[gpu.driver gpu.opengl benchmark.opengl benchmark.vulkan].each do |id|
      assert_select "li#check-#{id.gsub(".", "\\.")} .status.status-gap", "GAP"
      assert_select "li#check-#{id.gsub(".", "\\.")} .badge-missing", "not yet supported by Asahi"
    end
    assert_select "dd .gap", /\A\d+ gap\z/
  end

  test "the matrix has a row per build, filters to one and can merge a release's builds" do
    store_production

    get "/matrix", params: { group: "build" }
    assert_response :success
    m3 = css_select(%(tr.matrix-row[data-board="j613"])).sole
    assert_equal M3_BUILD, m3["data-build"]
    assert_select m3, ".row-build", "build #{BUILDS[M3]["words"]}"
    assert_select "select[name=build] option[value=?]", BUILDS[M3]["words"]
    builds = css_select("tr.matrix-row").map { |row| [ row["data-board"], row.at_css(".row-build").text ] }
    assert_equal builds.uniq, builds
    assert_equal BUILDS.values.map { |build| build["build"] }.uniq.sort, css_select("tr.matrix-row").map { |row| row["data-build"] }.uniq.sort
    # The M2 Max's runtime with a kernel installed by hand is its own row.
    assert_equal [ "build 1937418.362376005140001 (linux-aurora 7.1.12.aurora2-10, omarchy-mac-boot 20260926-1)",
                   "build 1937418.362376005140001 (linux-aurora 7.1.12.aurora2-10.90, omarchy-mac-boot 20260926-1)" ],
                 builds.select { |board, _| board == "j416c" }.map(&:last).sort

    get "/matrix", params: { group: "build", build: M1_AIR_BUILD }
    assert_equal [ M1_AIR_BUILD ], css_select("tr.matrix-row").map { |row| row["data-build"] }.uniq

    get "/matrix", params: { group: "release" }
    rows = css_select("tr.matrix-row")
    assert_equal [ "" ], rows.map { |row| row["data-build"].to_s }.uniq
    assert_equal rows.map { |row| row["data-board"] }.uniq.size, rows.size
    assert_select "tr.matrix-row .row-build", 0
  end

  test "model and feature pages show each build" do
    store_production

    get "/models/j613"
    label = "converged 4.0.0 · build #{BUILDS[M3]["words"]}"
    assert_select "th.config-head a[title=?]", label, "#1"
    assert_select ".configuration-key li#configuration-1", label
    assert_select "tr.report-row td.build-cell[data-build=?]", M3_BUILD

    get "/features/gpu"
    assert_select %(tr.result-row[data-board="j613"][data-build="#{M3_BUILD}"])
  end

  test "the candidates page maps each build to its candidate set when it's known" do
    store_production

    get "/candidates"
    assert_response :success
    air = css_select(%(tr.build-row[data-build="#{M1_AIR_BUILD}"])).sole
    assert_equal "apple-test-0052582276d9-20260927", air["data-set"]
    assert_equal "packages", air["data-set-source"]
    assert_select air, "td", /matched by package/
    # The M3 was installed outside the official installer, from a build no known set holds.
    m3 = css_select(%(tr.build-row[data-build="#{M3_BUILD}"])).sole
    assert_equal "", m3["data-set"].to_s
    assert_select m3, "td", "unknown"
    # The same runtime with a hand-installed kernel is its own build.
    assert_equal 3, css_select(%(tr.build-row[data-build="1937418.362376005140001"])).size
    # Matched runs don't make a candidate set of their own.
    assert_select "tr.candidate-row", 0
  end

  SET = "apple-test-1937418f520b-20260926"
  # A new image's target record, every key (omacom/omarchy-mac-installer#35).
  IMAGE = { "format" => "1", "platform" => "apple-silicon", "candidate_set" => SET,
            "candidate_source_commit" => "1937418f520b" + "0" * 28, "builder_commit" => "c6fedc32c" + "1" * 31,
            "builder_tree_clean" => "true", "image_profile" => "test", "package_set_sha256" => "ab" * 32, "built" => "2026-09-28T03:04:05Z" }.freeze

  def on_new_image(image = IMAGE)
    golden("m2-max-converged").tap do |report|
      report["system"]["candidate_set"] = SET
      report["system"]["image"] = image
    end
  end

  test "a run on an image naming its set is labelled by the set, counted for it, and shows the image record" do
    body = upload_report on_new_image
    assert_response :created
    words = "#{SET} (runtime 1937418.362376005140001, linux-aurora 7.1.12.aurora2-10, omarchy-mac-boot 20260926-1, " \
            "built 2026-09-28T03:04:05Z, package set abababababab)"
    assert_equal words, Report.sole.build.words

    get path_of(body["report_url"])
    assert_select "dd#build .build-id", SET
    assert_select "dd#build a[href=?]", "/candidates/#{SET}"
    assert_select "dd#build", /runtime 1937418\.362376005140001 · linux-aurora 7\.1\.12\.aurora2-10 · omarchy-mac-boot 20260926-1 · built 2026-09-28T03:04:05Z/
    assert_select "dd#image", "format 1, platform apple-silicon, candidate_set #{SET}, candidate_source_commit 1937418f520b, " \
                              "builder_commit c6fedc32c111, builder_tree_clean true, image_profile test, package_set_sha256 abababababab, " \
                              "built 2026-09-28T03:04:05Z"
    assert_select "dd#build", /built 2026-09-28T03:04:05Z · tester/

    get "/candidates"
    assert_select %(tr.build-row[data-set-source="image"] a.build-id), SET
    assert_select "tr#candidate-#{SET}"

    get "/matrix", params: { group: "build" }
    assert_select "select[name=build] option[value=?]", words, "#{SET} (1)"
  end

  test "two images of one set are two builds: the image's package set and build time tell them apart" do
    upload_report on_new_image, machine: "a"
    upload_report on_new_image(IMAGE.merge("built" => "2026-09-29T01:00:00Z")), machine: "b"
    upload_report on_new_image(IMAGE.merge("package_set_sha256" => "cd" * 32)), machine: "c"

    get "/candidates"
    assert_equal 3, css_select(%(tr.build-row[data-set="#{SET}"])).size

    get "/matrix", params: { group: "build" }
    assert_equal 3, css_select(%(tr.matrix-row[data-board="j416c"])).size
    Report.all.each do |report|
      get "/matrix", params: { group: "build", build: report.build.words }
      assert_select "tr.matrix-row", 1
      get "/reports", params: { build: report.build.words }
      assert_equal [ "report-#{report.public_id}" ], css_select("tr.report-row").map { |row| row["id"] }
    end
    get "/reports", params: { build: SET }
    assert_select "tr.report-row", 3
  end

  test "the image record takes only the builder's keys, each in its shape" do
    upload_report on_new_image(IMAGE.merge("hostname" => "omarchy-marcelo"))
    assert_response :unprocessable_content
    upload_report on_new_image(IMAGE.merge("built" => "Sep 28 2026")), machine: "b"
    assert_response :unprocessable_content
    upload_report on_new_image(IMAGE.merge("package_set_sha256" => "marcelo")), machine: "c"
    assert_response :unprocessable_content
    # A second line can't ride on a field's pattern.
    upload_report on_new_image(IMAGE.merge("image_profile" => "test\nhostname=omarchy-marcelo")), machine: "d"
    assert_response :unprocessable_content
    assert_equal 0, Report.count
  end

  test "exports carry the build of every report" do
    store_production

    get "/api/v1/reports.json"
    exported = response.parsed_body["reports"].to_h { |entry| [ entry["id"], entry ] }
    BUILDS.each { |id, build| assert_equal build["words"], exported.dig(id, "build", "words") }
    assert_equal({ "id" => M3_BUILD, "label" => M3_BUILD, "commit" => "f60e1ba", "stamp" => "2026092602", "linux_aurora" => "7.1.12.aurora2-11",
                   "omarchy_mac_boot" => "20260926-1", "tool_version" => "0.1.8" }, exported.dig(M3, "build").except("words"))
    assert_equal "apple-test-0052582276d9-20260927", exported.dig("q8avqMwJH59VSjxM5TxAyF38", "build", "candidate_set")
    # The report itself stays exactly as uploaded.
    assert_equal PRODUCTION.find { |entry| entry["id"] == M3 }["report"].except("signature"), exported.dig(M3, "report")

    get "/api/v1/reports.csv"
    rows = response.body.split("\r\n").map { |line| line.scan(/"((?:[^"]|"")*)"/).flatten }
    m3 = rows.drop(1).map { |row| rows[0].zip(row).to_h }.find { |row| row["id"] == M3 }
    assert_equal [ M3_BUILD, "f60e1ba", "2026092602", "7.1.12.aurora2-11", "20260926-1", "" ],
                 m3.values_at("build", "build_commit", "build_stamp", "linux_aurora", "omarchy_mac_boot", "build_candidate_set")
    assert_operator m3["expected_gaps"].to_i, :>=, 4

    get "/api/v1/checks.csv"
    rows = response.body.split("\r\n").map { |line| line.scan(/"((?:[^"]|"")*)"/).flatten }
    assert_equal [ M3_BUILD ], rows.drop(1).map { |row| rows[0].zip(row).to_h }.select { |row| row["report_id"] == M3 }.map { |row| row["build"] }.uniq

    get "/api/v1/matrix.json"
    row = response.parsed_body["rows"].find { |r| r["board"] == "j613" }
    assert_equal [ "4.0.0", M3_BUILD ], [ row["version"], row.dig("build", "id") ]
  end
end
