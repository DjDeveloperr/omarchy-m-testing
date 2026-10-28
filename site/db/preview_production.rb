# Load public production exports into a separate local development database:
# DATABASE_URL=postgresql:///omarchy_m_testing_production_preview bin/rails runner \
#   db/preview_production.rb reports.json tester-reports.json
abort "Production previews can only be loaded in development." unless Rails.env.development?
configuration = ActiveRecord::Base.connection_db_config
abort "Use the separate omarchy_m_testing_production_preview database." unless configuration.database == "omarchy_m_testing_production_preview"
host = configuration.configuration_hash[:host] || ENV["PGHOST"]
abort "Use a local database for the production preview." if host.present? && !host.start_with?("/") && !%w[localhost 127.0.0.1 ::1].include?(host)
abort "Usage: bin/rails runner db/preview_production.rb reports.json tester-reports.json" unless ARGV.size == 2

export = JSON.parse(File.read(ARGV[0]))
tester_export = JSON.parse(File.read(ARGV[1]))
abort "The second file must be the runs=tester public export." unless tester_export.dig("filters", "runs") == "tester"
tester_ids = tester_export.fetch("reports").map { |entry| entry.fetch("id") }

records = export.fetch("reports").map do |entry|
  id = entry.fetch("id")
  abort "Invalid public report id in the export." unless id.is_a?(String) && id.match?(/\A[a-zA-Z0-9]{24}\z/)
  body = entry.fetch("report")
  problems = ReportSchema.errors(body) + Catalogue.unknown_check_ids(body) + ReportEvidence.errors(body)
  abort "Production report #{id} is invalid: #{problems.join('; ')}" if problems.any?
  at = Time.iso8601(entry.fetch("uploaded_at"))
  {
    public_id: id, body:, schema_version: body.fetch("schema_version"), created_at: at, updated_at: at,
    # Public exports deliberately omit machine identity and grouping. Do not
    # invent distinct machines, which would falsely confirm community results.
    machine_id: nil, tester_login: ("production-preview-tester" if tester_ids.include?(id)), hidden_at: nil
  }
end
ids = records.map { |record| record.fetch(:public_id) }
abort "The export has duplicate public report ids." unless ids.uniq.size == ids.size
abort "The tester export contains reports missing from the full export. Download both again." unless (tester_ids - ids).empty?

Report.transaction do
  Tester.find_or_create_by!(login: "production-preview-tester") if tester_ids.any?
  Report.delete_all
  records.each { |attributes| Report.create!(attributes) }
end

snapshot = {
  source: "https://omarchy-m-testing.org/api/v1/reports.json",
  exported_at: export.fetch("generated_at"), imported_at: Time.current.utc.iso8601,
  reports: records.size, models: records.map { |record| record.dig(:body, "machine", "board") }.uniq.size,
  tester_reports: tester_ids.size, machine_grouping: "unknown",
  source_sha256: Report.digest(File.binread(ARGV[0]))
}
Rails.root.join("tmp", "production-preview.json").write(JSON.pretty_generate(snapshot) + "\n")
puts "Loaded #{snapshot[:reports]} unchanged production reports across #{snapshot[:models]} models (#{snapshot[:tester_reports]} tester reports)."
puts "Public exports omit private machine grouping; imported reports do not establish agreement between distinct machines."
