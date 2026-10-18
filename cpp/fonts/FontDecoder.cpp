#include "FontDecoder.h"
#include <woff2/decode.h>
#include <woff2/output.h>
#include <fstream>
#include <stdexcept>
#include <vector>

namespace expo_mpv {
void decodeWoff2(const std::string &inputPath, const std::string &outputPath) {
  constexpr size_t maxInputSize = 32 * 1024 * 1024;
  constexpr size_t maxOutputSize = 32 * 1024 * 1024;
  std::ifstream input(inputPath, std::ios::binary | std::ios::ate);
  const auto length = input.tellg();
  if (!input || length < 48 || static_cast<size_t>(length) > maxInputSize)
    throw std::runtime_error("Invalid WOFF2 file size");
  std::vector<uint8_t> data(static_cast<size_t>(length));
  input.seekg(0);
  if (!input.read(reinterpret_cast<char *>(data.data()), length))
    throw std::runtime_error("Unable to read WOFF2 font");
  const size_t decodedSize = woff2::ComputeWOFF2FinalSize(data.data(), data.size());
  if (!decodedSize || decodedSize > maxOutputSize)
    throw std::runtime_error("Invalid decoded font size");
  std::string decoded;
  woff2::WOFF2StringOut output(&decoded);
  output.SetMaxSize(maxOutputSize);
  if (!woff2::ConvertWOFF2ToTTF(data.data(), data.size(), &output))
    throw std::runtime_error("Unable to decode WOFF2 font");
  std::ofstream file(outputPath, std::ios::binary | std::ios::trunc);
  if (!file.write(decoded.data(), decoded.size()))
    throw std::runtime_error("Unable to write decoded font");
}
}
