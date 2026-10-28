class ModelsController < ApplicationController
  def index
    reports = Report.visible.to_a
    @lineup = MacLineup.new(reports)
    @matrix = CompatibilityMatrix.visible(reports:)
    @models = @matrix.rows.group_by { |row| row.configuration.board }
  end

  def show
    @matrix = CompatibilityMatrix.visible
    @rows = @matrix.rows_for_board(params[:board])
    raise ActiveRecord::RecordNotFound if @rows.empty?

    @latest = @rows.flat_map(&:reports).max_by(&:created_at)
    @chip = Catalogue.chip_for_soc(@latest.soc)
    @benchmarks = BenchmarkScores.visible.for_board(params[:board])
  end
end
