#include <base/hex.h>
#include <Common/StringUtils.h>
#include <Common/escapeForFileName.h>

namespace DB
{

void appendEscapedForFileName(std::string & to, std::string_view s)
{
    const char * pos = s.data();
    const char * end = pos + s.size();

    while (pos != end)
    {
        /// Most names have no characters to escape, so append whole runs of word characters at once.
        const char * run_end = pos;
        while (run_end != end && isWordCharASCII(*run_end))
            ++run_end;

        to.append(pos, run_end);
        if (run_end == end)
            break;

        unsigned char c = *run_end;
        const char escaped[3] = {'%', hexDigitUppercase(c / 16), hexDigitUppercase(c % 16)};
        to.append(escaped, 3);
        pos = run_end + 1;
    }
}

std::string escapeForFileName(const std::string & s)
{
    std::string res;
    res.reserve(s.size());
    appendEscapedForFileName(res, s);
    return res;
}

std::string unescapeForFileName(const std::string & s)
{
    std::string res;
    const char * pos = s.data();
    const char * end = pos + s.size();

    while (pos != end)
    {
        if (!(*pos == '%' && pos + 2 < end))
        {
            res += *pos;
            ++pos;
        }
        else
        {
            ++pos;
            res += unhex2(pos);
            pos += 2;
        }
    }
    return res;
}

}
