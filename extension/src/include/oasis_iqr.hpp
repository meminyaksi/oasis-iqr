#pragma once

#include "duckdb.hpp"
#include "duckdb/main/extension/extension_loader.hpp"

namespace duckdb {

// Registers the `iqr_flags(path VARCHAR, column VARCHAR)` table function: streams one 64-bit column
// of a Parquet file through the IQR_detection vFPGA operator and returns, per row, the value and an
// `is_outlier` flag (1.5*IQR rule, computed in hardware).
void RegisterOasisIqrFunction(ExtensionLoader &loader);

} // namespace duckdb
