#pragma once

#include <string>
#include <string_view>


namespace DB
{

/** Convert a string, so result could be used as a file name.
  * In fact it percent-encode all non-word characters, as in URL.
  */

std::string escapeForFileName(const std::string & s);
/// Appends escapeForFileName(s) to `to` without a temporary string.
void appendEscapedForFileName(std::string & to, std::string_view s);
std::string unescapeForFileName(const std::string & s);

}
