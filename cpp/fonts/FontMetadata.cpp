#include "FontDecoder.h"
#include <algorithm>
#include <fstream>
#include <stdexcept>
#include <zlib.h>

namespace expo_mpv {
namespace {
using Bytes = std::vector<uint8_t>;
uint16_t u16(const Bytes &data, size_t offset) {
  if (offset > data.size() || data.size() - offset < 2) throw std::runtime_error("Invalid font table");
  return (data[offset] << 8) | data[offset + 1];
}
uint32_t u32(const Bytes &data, size_t offset) {
  return (static_cast<uint32_t>(u16(data, offset)) << 16) | u16(data, offset + 2);
}
Bytes slice(const Bytes &data, size_t offset, size_t length) {
  if (offset > data.size() || length > data.size() - offset) throw std::runtime_error("Invalid font table bounds");
  return Bytes(data.begin() + offset, data.begin() + offset + length);
}
void utf8(std::string &output, uint32_t character) {
  if (character < 0x80) output += static_cast<char>(character);
  else if (character < 0x800) {
    output += static_cast<char>(0xc0 | (character >> 6));
    output += static_cast<char>(0x80 | (character & 0x3f));
  } else if (character < 0x10000) {
    output += static_cast<char>(0xe0 | (character >> 12));
    output += static_cast<char>(0x80 | ((character >> 6) & 0x3f));
    output += static_cast<char>(0x80 | (character & 0x3f));
  } else {
    output += static_cast<char>(0xf0 | (character >> 18));
    output += static_cast<char>(0x80 | ((character >> 12) & 0x3f));
    output += static_cast<char>(0x80 | ((character >> 6) & 0x3f));
    output += static_cast<char>(0x80 | (character & 0x3f));
  }
}
std::string familyName(const Bytes &table) {
  const auto count = u16(table, 2), strings = u16(table, 4);
  int best = -1;
  std::string result;
  for (size_t index = 0; index < count; index++) {
    const size_t entry = 6 + index * 12;
    const auto platform = u16(table, entry), language = u16(table, entry + 4), id = u16(table, entry + 6);
    if ((id != 1 && id != 16) || (platform != 0 && platform != 3 && platform != 1)) continue;
    const auto bytes = slice(table, static_cast<size_t>(strings) + u16(table, entry + 10), u16(table, entry + 8));
    std::string value;
    for (size_t offset = 0; offset < bytes.size();) {
      uint32_t character;
      if (platform == 1) { character = bytes[offset++]; if (character >= 128) { value.clear(); break; } }
      else {
        character = u16(bytes, offset); offset += 2;
        if (character >= 0xd800 && character <= 0xdbff) {
          const auto low = u16(bytes, offset); offset += 2;
          if (low < 0xdc00 || low > 0xdfff) throw std::runtime_error("Invalid font name encoding");
          character = 0x10000 + ((character - 0xd800) << 10) + low - 0xdc00;
        } else if (character >= 0xdc00 && character <= 0xdfff) throw std::runtime_error("Invalid font name encoding");
      }
      if (character < 32 || character == 127) throw std::runtime_error("Invalid font family name");
      utf8(value, character);
    }
    const int score = (id == 16 ? 20 : 0) + (language == 0x409 ? 10 : 0) + (platform != 1 ? 2 : 0);
    if (!value.empty() && value.size() <= 1024 && score > best) { best = score; result = value; }
  }
  return result;
}
Bytes nameTable(const Bytes &data, size_t face) {
  const bool woff = u32(data, face) == 0x774f4646;
  const auto count = u16(data, face + (woff ? 12 : 4));
  for (size_t index = 0; index < count; index++) {
    const size_t entry = face + (woff ? 44 + index * 20 : 12 + index * 16);
    if (u32(data, entry) != 0x6e616d65) continue;
    const auto length = u32(data, entry + (woff ? 8 : 12));
    if (length > 1024 * 1024) throw std::runtime_error("Invalid font name table size");
    auto bytes = slice(data, u32(data, entry + (woff ? 4 : 8)), length);
    if (woff) {
      const auto original = u32(data, entry + 12);
      if (original > 1024 * 1024 || length > original) throw std::runtime_error("Invalid font name table size");
      if (original != length) {
        Bytes decoded(original);
        uLongf size = original;
        if (uncompress(decoded.data(), &size, bytes.data(), bytes.size()) != Z_OK || size != original)
          throw std::runtime_error("Invalid compressed font name table");
        return decoded;
      }
    }
    return bytes;
  }
  throw std::runtime_error("Font has no family name table");
}
}
std::vector<std::string> fontFamilies(const std::string &path) {
  std::ifstream file(path, std::ios::binary | std::ios::ate);
  const auto size = file.tellg();
  if (!file || size < 12 || size > 32 * 1024 * 1024) throw std::runtime_error("Invalid font size");
  Bytes data(static_cast<size_t>(size));
  file.seekg(0);
  if (!file.read(reinterpret_cast<char *>(data.data()), size)) throw std::runtime_error("Unable to read font");
  const auto signature = u32(data, 0);
  if (signature != 0x74746366 && signature != 0x00010000 && signature != 0x4f54544f &&
      signature != 0x74727565 && signature != 0x774f4646) throw std::runtime_error("Unsupported font format");
  const auto count = signature == 0x74746366 ? u32(data, 8) : 1;
  if (!count || count > 64) throw std::runtime_error("Invalid font collection");
  std::vector<std::string> families;
  for (size_t index = 0; index < count; index++) {
    const auto family = familyName(nameTable(data, signature == 0x74746366 ? u32(data, 12 + index * 4) : 0));
    if (!family.empty() && std::find(families.begin(), families.end(), family) == families.end()) families.push_back(family);
  }
  if (families.empty()) throw std::runtime_error("Font has no usable family name");
  return families;
}
}
