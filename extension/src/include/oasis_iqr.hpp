#pragma once

#include "duckdb.hpp"
#include "duckdb/main/extension/extension_loader.hpp"

namespace duckdb {

// Registers the IQR outlier-detection table functions (1.5*IQR rule), both returning one BOOLEAN
// `is_outlier` row per row of a 64-bit integer Parquet column:
//   iqr_flags_only(path VARCHAR, column VARCHAR)         -- decoded and flagged on the FPGA
//   iqr_cpu_flags_groupby(path VARCHAR, column VARCHAR)  -- CPU baseline with exact quartiles
void RegisterOasisIqrFunction(ExtensionLoader &loader);

} // namespace duckdb
