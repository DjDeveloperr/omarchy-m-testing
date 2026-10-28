# Load with: bin/rails runner db/preview_seeds.rb
# Separate from db/seeds.rb so example reports never enter production.
abort "Preview data can only be loaded in development." unless Rails.env.development?

tester = Tester.find_or_create_by!(login: "demo-tester")
tester.update!(github_id: 4242)

samples = JSON.parse(ReportSchema.dir.join("golden", "production", "reports.json").read).fetch("reports")
samples = samples.each_with_index.map do |entry, index|
  { body: entry.fetch("report"), at: Time.iso8601(entry.fetch("uploaded_at")),
    machine: "snapshot-#{index}", tester: ("demo-tester" if index % 3 == 0) }
end

# Two tester machines retest the same feature, then one skips it. The
# matrix retains the failure and its verified earlier pass as a regression.
base = JSON.parse(ReportSchema.dir.join("golden", "m2-max-image2.json").read)
%w[works fails not-tested].each_with_index do |outcome, index|
  machines = outcome == "not-tested" ? %w[demo-a] : %w[demo-a demo-b]
  machines.each do |machine|
    body = base.deep_dup
    check = body.fetch("checks").find { |item| item["id"] == "display.backlight" }
    check["status"] = { "works" => "pass", "fails" => "fail", "not-tested" => "skip" }.fetch(outcome)
    check["classification"]["outcome"] = outcome
    check.delete("answered_by_default")
    check["evidence"] = [ "Local preview: synthetic #{outcome} example." ]
    samples << { body:, at: (3 - index).hours.ago, machine:, tester: "demo-tester" }
  end
end
samples << { body: JSON.parse(ReportSchema.dir.join("golden", "benchmarks", "m2-max-converged.json").read),
             at: 30.minutes.ago, machine: "demo-a", tester: "demo-tester" }

Report.transaction do
  samples.each_with_index do |sample, index|
    body = sample.fetch(:body).except("signature")
    errors = ReportSchema.errors(body) + Catalogue.unknown_check_ids(body) + ReportEvidence.errors(body)
    raise "Preview report #{index} is invalid: #{errors.join(', ')}" if errors.any?

    report = Report.find_or_initialize_by(public_id: "preview-#{index.to_s.rjust(16, '0')}")
    report.assign_attributes(body:, schema_version: body.fetch("schema_version"),
                             machine_id: "preview:#{Report.digest(sample.fetch(:machine)).first(20)}",
                             tester_login: sample[:tester], hidden_at: nil, created_at: sample.fetch(:at), updated_at: sample.fetch(:at))
    report.save!
  end
end

puts "Loaded #{samples.size} preview reports (tester and community runs, multiple builds, a regression, skipped checks and benchmarks)."
