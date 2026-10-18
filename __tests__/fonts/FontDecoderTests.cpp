#include "FontDecoder.h"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <vector>
#include <zlib.h>

namespace fs = std::filesystem;
void check(bool condition, const char *message) {
  if (!condition) throw std::runtime_error(message);
}
using Bytes = std::vector<uint8_t>;
void put(Bytes &bytes, size_t offset, uint32_t value, size_t width) {
  for (size_t index = 0; index < width; index++) bytes.at(offset + index) = value >> (8 * (width - index - 1));
}
Bytes names(const std::u16string &value) {
  Bytes table(18 + value.size() * 2);
  put(table, 2, 1, 2); put(table, 4, 18, 2);
  put(table, 6, 3, 2); put(table, 8, 1, 2); put(table, 10, 0x409, 2);
  put(table, 12, 16, 2); put(table, 14, value.size() * 2, 2);
  for (size_t index = 0; index < value.size(); index++) put(table, 18 + index * 2, value[index], 2);
  return table;
}
void metadataTests(const fs::path &directory) {
  const auto name = names(u"字幕字体, Test\U0001F408");
  Bytes sfnt(28);
  put(sfnt, 0, 0x00010000, 4); put(sfnt, 4, 1, 2);
  put(sfnt, 12, 0x6e616d65, 4); put(sfnt, 20, 28, 4); put(sfnt, 24, name.size(), 4);
  sfnt.insert(sfnt.end(), name.begin(), name.end());
  const auto file = directory / "metadata.font";
  auto inspect = [&](const Bytes &bytes) {
    std::ofstream(file, std::ios::binary).write(reinterpret_cast<const char *>(bytes.data()), bytes.size());
    return expo_mpv::fontFamilies(file.string());
  };
  const std::vector<std::string> expected{"字幕字体, Test\xF0\x9F\x90\x88"};
  check(inspect(sfnt) == expected, "Unicode and supplementary characters must survive metadata decoding");
  Bytes collection(20);
  put(collection, 0, 0x74746366, 4); put(collection, 4, 0x00010000, 4);
  put(collection, 8, 2, 4); put(collection, 12, 20, 4); put(collection, 16, 20 + sfnt.size(), 4);
  for (int index = 0; index < 2; index++) {
    auto face = sfnt;
    put(face, 20, collection.size() + 28, 4);
    collection.insert(collection.end(), face.begin(), face.end());
  }
  check(inspect(collection) == expected, "Collection faces must use absolute offsets and deduplicate families");
  Bytes compressed(compressBound(name.size()));
  uLongf length = compressed.size();
  check(compress(compressed.data(), &length, name.data(), name.size()) == Z_OK, "Test compression must succeed");
  compressed.resize(length);
  Bytes woff(64);
  put(woff, 0, 0x774f4646, 4); put(woff, 12, 1, 2);
  put(woff, 44, 0x6e616d65, 4); put(woff, 48, 64, 4);
  // Tiny tables may be stored uncompressed, as required when zlib increases the size.
  const auto &payload = compressed.size() < name.size() ? compressed : name;
  put(woff, 52, payload.size(), 4); put(woff, 56, name.size(), 4);
  woff.insert(woff.end(), payload.begin(), payload.end());
  check(inspect(woff) == expected, "WOFF name tables must be decoded");
  for (size_t size = 0; size < sfnt.size(); size++) {
    bool rejected = false;
    try { inspect(Bytes(sfnt.begin(), sfnt.begin() + size)); }
    catch (const std::exception &) { rejected = true; }
    check(rejected, "Truncated name tables must be rejected");
  }
  put(sfnt, 20, 0xffffffff, 4);
  bool rejected = false;
  try { inspect(sfnt); } catch (const std::exception &) { rejected = true; }
  check(rejected, "Out-of-bounds metadata offsets must be rejected");
}
int main(int argc, char **argv) {
  check(argc == 3, "Expected fixture and temporary output directory");
  const fs::path fixture = argv[1], directory = argv[2];
  fs::create_directories(directory);
  metadataTests(directory);
  const auto output = directory / "font.ttf";
  expo_mpv::decodeWoff2(fixture.string(), output.string());
  std::ifstream decoded(output, std::ios::binary);
  char signature[4] = {};
  decoded.read(signature, 4);
  check(signature[0] == 0 && signature[1] == 1 && signature[2] == 0 && signature[3] == 0,
        "Decoded font must have a TrueType signature");
  check(fs::file_size(output) > fs::file_size(fixture), "Font must be decompressed");
  check(expo_mpv::fontFamilies(output.string()) == std::vector<std::string>{"NekoFin Font Test"},
        "The embedded font family must be read from its name table");

  auto rejects = [&](const fs::path &input, const fs::path &destination) {
    bool failed = false;
    try { expo_mpv::decodeWoff2(input.string(), destination.string()); }
    catch (const std::exception &) { failed = true; }
    check(failed, "Invalid input/output must be rejected");
  };
  rejects(directory / "missing", output);
  const auto truncated = directory / "truncated.woff2";
  std::ofstream(truncated) << "wOF2";
  rejects(truncated, output);
  std::ifstream input(fixture, std::ios::binary);
  std::vector<char> bytes((std::istreambuf_iterator<char>(input)), {});
  bytes[0] = 0;
  const auto corrupt = directory / "corrupt.woff2";
  std::ofstream(corrupt, std::ios::binary).write(bytes.data(), bytes.size());
  rejects(corrupt, output);
  bytes[0] = 'w';
  for (int index = 16; index < 20; index++) bytes[index] = static_cast<char>(0xff);
  const auto oversized = directory / "oversized.woff2";
  std::ofstream(oversized, std::ios::binary).write(bytes.data(), bytes.size());
  rejects(oversized, output);
  rejects(fixture, directory / "missing" / "font.ttf");
  std::cout << "PASS: font decoding, truncation, corruption, output limit and IO failures\n";
}
