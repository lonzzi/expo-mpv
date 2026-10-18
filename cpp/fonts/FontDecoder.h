#pragma once
#include <string>
#include <vector>

namespace expo_mpv {
void decodeWoff2(const std::string &inputPath, const std::string &outputPath);
std::vector<std::string> fontFamilies(const std::string &path);
}
