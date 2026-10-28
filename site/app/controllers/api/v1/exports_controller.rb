module Api
  module V1
    # The rest of the public data, CC0: every check result as CSV, and the
    # compatibility matrix, the benchmark comparison and the Aurora
    # feature-support table as JSON. The checks and the matrix take the
    # filters the pages do (ReportFilter), and the matrix ?group=release.
    class ExportsController < ActionController::API
      def checks
        send_data DataExport.checks_csv(ReportFilter.new(params)), type: "text/csv; charset=utf-8", filename: "omarchy-m-testing-checks.csv"
      end

      def matrix
        render json: { license: DataExport::LICENSE, generated_at: Time.current.utc.iso8601, **matrix_json }
      end

      def benchmarks
        render json: { license: DataExport::LICENSE, generated_at: Time.current.utc.iso8601, **BenchmarkScores.visible.as_json }
      end

      def aurora
        render json: { license: DataExport::LICENSE, note: DataExport::ASAHI_NOTE, generated_at: Time.current.utc.iso8601,
                       **AuroraSupport.visible.as_json(->(report) { report_url(report) }) }
      end

      private

      def matrix_json
        filter = ReportFilter.new(params)
        by_model = params[:group] == "model"
        matrix = CompatibilityMatrix.visible(by_build: params[:group] != "release", by_model:, filter:)
        json = filter.any? || by_model ? { filters: filter.values, runs: matrix.runs_count, **matrix.as_json } : matrix.as_json
        by_model ? json.merge(group: "model") : json
      end
    end
  end
end
