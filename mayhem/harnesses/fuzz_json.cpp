/* oneDNN graph JSON-deserializer fuzz harness — adapted from the upstream OSS-Fuzz harness
 * (oss-fuzz/projects/onednn/fuzz_json.cpp). Exercises
 * dnnl::impl::graph::utils::json::json_reader_t / read_helper_t (src/graph/utils/json.hpp),
 * oneDNN graph's JSON deserialization utility — the same class src/graph/utils/pm/pass_manager.cpp
 * uses internally to load a pass_config.json (see its "pass_name"/"pass_backend"/"priority"/
 * "enable"/"kind" field declarations). That class is HEADER-ONLY (fully inline in json.hpp): it
 * needs no compiled oneDNN library to build or exercise, so mayhem/build.sh links only this file
 * against the header — no cmake, no libdnnl.a.
 *
 * KAT extension (read by mayhem/test.sh): upstream's harness declares NO fields on its
 * read_helper_t (an empty field map), so it only ever advances past the FIRST top-level key
 * before read_fields() bails out — it can't exercise value dispatch at all. To get a real
 * behavioral oracle (SPEC section 6.3: known-input to known-OUTPUT, not "didn't crash") we
 * additionally declare three fields of the same KINDS oneDNN's own loader declares (a string, an
 * integer, an array of integers) and, only when MAYHEM_KAT_PRINT is set, print a value COMPUTED
 * from what was actually parsed (the product of the "dims" array) rather than an echo of the
 * input. This is additive to the fuzzed surface, not a replacement: the parser still runs over
 * the full attacker-controlled byte stream and swallows any parse exception exactly like
 * upstream — declaring extra fields only widens the code paths malformed input can reach.
 */

#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

#include "json.hpp"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  std::string input(reinterpret_cast<const char *>(data), size);

  const char *fuzz_filename = "/tmp/fuzz_json_input.json";
  {
    std::ofstream out(fuzz_filename, std::ios::binary);
    out.write(input.c_str(), (std::streamsize)size);
  }

  std::ifstream fs(fuzz_filename);
  dnnl::impl::graph::utils::json::json_reader_t read(&fs);
  dnnl::impl::graph::utils::json::read_helper_t helper;

  std::string op_kind;
  int64_t version = -1;
  std::vector<int64_t> dims;
  helper.declare_field("op_kind", &op_kind);
  helper.declare_field("version", &version);
  helper.declare_field("dims", &dims);

  try {
    helper.read_fields(&read);
  } catch (...) {
    // Upstream's contract: malformed/attacker-controlled input must not crash the process;
    // parse errors are swallowed, exactly like the original OSS-Fuzz harness.
  }

  if (std::getenv("MAYHEM_KAT_PRINT")) {
    int64_t dims_product = dims.empty() ? 0 : 1;
    for (int64_t d : dims) dims_product *= d;
    std::cout << "KAT op_kind=" << op_kind << " version=" << version
               << " dims_product=" << dims_product << std::endl;
  }

  return 0;
}
