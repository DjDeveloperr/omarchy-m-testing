# The compatibility matrix: one row per Mac model, Omarchy stack/version and
# build (Build: the runtime commit and build stamp, kernel and boot package),
# one cell per catalogue feature some check tests, from the visible reports.
# by_build: false merges a release's builds into one row ("converged 4.0.0").
# by_model: true merges releases too, with each machine's latest actual check results per stack.
class CompatibilityMatrix
  STACKS = %w[converged mx-mac legacy-omarchy-mac reference].freeze

  Row = Data.define(:configuration, :model_name, :chip, :soc, :reports, :cells) do
    def cell(feature_id) = cells.fetch(feature_id) { MatrixCell.new({}, []) }
  end

  # build: only the runs on that build (Build#id). filter: a ReportFilter, which takes the place of stack and build.
  # reports: the visible reports, when the caller has them already.
  def self.visible(stack: nil, build: nil, by_build: true, by_model: false, filter: nil, reports: nil)
    filter ||= ReportFilter.new({ "stack" => stack, "build" => build })
    new(filter.runs(reports || Report.visible.to_a), by_build:, by_model:, filter:)
  end

  # The builds of the visible reports the filter's other filters pass, newest run first: [[build, runs], ...] (Build.runs).
  def self.builds(stack: nil, filter: nil, reports: nil)
    filter = ReportFilter.new((filter&.values || { "stack" => stack }).except("build"))
    Build.runs(filter.runs(reports || Report.visible.to_a))
  end

  # only_testers: cells from tester runs only (a candidate set's view). filter: a ReportFilter's result
  # filters (the runs are already chosen): confirmed cells only, one layer's columns, the rows and columns with a state.
  def initialize(reports, only_testers: false, by_build: true, by_model: false, filter: nil)
    @reports = reports.sort_by { |report| [ report.created_at, report.id ] }
    @only_testers = only_testers
    @by_build = by_build
    @by_model = by_model
    @filter = filter || ReportFilter.new
  end

  def reports = @reports.reverse

  # The runs behind the rows shown (fewer than reports when result filters leave rows out).
  def runs_count = rows.sum { |row| row.reports.size }
  def empty? = @reports.empty?

  # The columns: the catalogue's tested features, of the filter's layer, and with its state in some row.
  def features
    @features ||= begin
      features = Catalogue.tested_features
      features = features.select { |feature| feature.fetch("layer") == @filter.layer } if @filter.layer
      features = features.select { |feature| all_rows.any? { |row| state?(row.cell(feature.fetch("id"))) } } if @filter.state
      features
    end
  end

  # The rows: with confirmed only, those with a confirmed cell; with a state, those with a cell in it.
  def rows
    @rows ||= all_rows.select do |row|
      cells = features.map { |feature| row.cell(feature.fetch("id")) }
      (!@filter.confirmed? || cells.any? { |cell| !cell.hidden? && !cell.tallies.empty? }) &&
        (!@filter.state || cells.any? { |cell| state?(cell) })
    end
  end

  def rows_for_board(board) = rows.select { |row| row.configuration.board == board }

  # Rows with at least one report that tested the feature.
  def rows_for_feature(feature_id) = rows.select { |row| row.cell(feature_id).reports.any? }

  def as_json(*)
    shown = features.map { |feature| feature.fetch("id") }
    {
      catalogue_version: Catalogue.version,
      agreement: "a cell's state is set by tester runs on their own, or once #{MatrixCell::AGREEMENT} or more distinct machines agree; null while unconfirmed",
      features: features.map { |f| { id: f["id"], name: f["name"], layer: f["layer"] } },
      rows: rows.map do |row|
        row_json = {
          model: row.model_name, board: row.configuration.board, soc: row.soc, chip: row.chip,
          stack: row.configuration.stack, version: row.configuration.version, build: (@by_model ? nil : row.reports.first.build&.as_json),
          reports: row.reports.size,
          cells: row.cells.slice(*shown).transform_values do |cell|
            json = { state: cell.state, tentative: cell.tentative, machines: cell.tallies, tester_machines: cell.tester_tallies }
            if @by_model
              sources = cell.sources
              json.merge!(kernels: sources.map(&:kernel).uniq, last_tested_at: sources.first&.created_at&.utc&.iso8601)
            end
            cell.hidden? ? json.merge(hidden: true) : json
          end
        }
        row_json[:releases] = row.reports.map(&:omarchy_version).uniq if @by_model
        row_json
      end
    }
  end

  private

  # Every row of the runs, each cell counted from them (with confirmed only, unconfirmed cells hidden).
  def all_rows
    @all_rows ||= @reports.group_by { |report| report.configuration(by_build: @by_build, by_model: @by_model) }.map do |configuration, reports|
      latest = reports.last
      cells = Catalogue.tested_features.to_h do |feature|
        cell = MatrixCell.from(reports, feature.fetch("id"), only_testers: @only_testers, per_check: @by_model)
        [ feature.fetch("id"), @filter.confirmed? ? cell.confirmed_only : cell ]
      end
      Row.new(configuration:, model_name: latest.short_model_name, chip: latest.chip, soc: latest.soc, reports: reports.reverse, cells:)
    end.sort { |a, b| compare(a, b) }
  end

  def state?(cell) = !cell.hidden? && @filter.matrix_states.include?(cell.display_state)

  # By chip generation, model and stack; within those, newest version first, then the newest build.
  def compare(a, b)
    order = (sort_key(a) <=> sort_key(b)).to_i
    order = version_key(b) <=> version_key(a) if order.zero?
    order.zero? ? b.reports.first.upload_order <=> a.reports.first.upload_order : order
  end

  def sort_key(row)
    [ Catalogue.chips.keys.index(Catalogue.chip_for_soc(row.soc)) || Catalogue.chips.size,
      row.model_name, STACKS.index(row.configuration.stack) || STACKS.size ]
  end

  def version_key(row)
    Gem::Version.new(row.configuration.version || "0")
  rescue ArgumentError
    Gem::Version.new("0")
  end
end
