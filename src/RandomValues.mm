// Random Values — macOS port of the Notepad++ "Random values" plugin.
//
// Original (Windows, C#/WinForms): Bas de Reuver (BdR76),
// https://github.com/BdR76/RandomValuesNPP  — GPL-style free-to-use.
//
// This macOS port reimplements the full feature set in Objective-C++:
//   * 5 user-configurable quick-insert menu items (Password, GUID, dice, …)
//   * Repeat last random value
//   * Generate random values window (grid of columns -> CSV/SQL/XML/JSON)
//   * Per-column Options dialog (width, case, mix-mask, pwsafe, empty %)
//   * Settings window (property-grid: General / Menu items / RandomGenerate /
//     RandomGenerateCols 01..30)
//   * About dialog, toolbar dice icon (light + dark)
//
// The random-value spec language matches the Windows version verbatim:
//   "Description" <type>(<mask>) {<range>} [<options>]
// so .ini files / column specs are interchangeable between platforms.
//
// Settings persist as an INI at the host plugins-config dir
// (~/.nextpad++/plugins/Config/Random values.ini), same key names as Windows.

#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"
#import <Cocoa/Cocoa.h>

#include <algorithm>
#include <random>
#include <string>
#include <sstream>
#include <vector>
#include <map>
#include <cmath>

// ===========================================================================
// Plugin identity + menu layout
// ===========================================================================
static const char *PLUGIN_NAME = "Random values";

enum MenuIdx {
    MI_Item1 = 0, MI_Item2, MI_Item3, MI_Item4, MI_Item5,
    MI_Sep1,
    MI_Repeat, MI_Generate,
    MI_Sep2,
    MI_Settings, MI_About,
    NB_FUNC
};

static FuncItem funcItem[NB_FUNC];
NppData nppData;

// ===========================================================================
// NPP / Scintilla helpers
// ===========================================================================
static intptr_t npp(uint32_t msg, uintptr_t w = 0, intptr_t l = 0) {
    return nppData._sendMessage(nppData._nppHandle, msg, w, l);
}
static NppHandle curSci() {
    int which = -1;
    npp(NPPM_GETCURRENTSCINTILLA, 0, (intptr_t)&which);
    return (which == 1) ? nppData._scintillaSecondHandle : nppData._scintillaMainHandle;
}
static intptr_t sci(uint32_t msg, uintptr_t w = 0, intptr_t l = 0) {
    return nppData._sendMessage(curSci(), msg, w, l);
}
static std::string sciEOL() {
    switch ((int)sci(SCI_GETEOLMODE)) {
        case SC_EOL_CRLF: return "\r\n";
        case SC_EOL_CR:   return "\r";
        default:          return "\n";
    }
}
static void sciReplaceSel(const std::string &s) {
    sci(SCI_REPLACESEL, 0, (intptr_t)s.c_str());
}

// ===========================================================================
// RNG — one shared engine so identically-configured columns differ
// ===========================================================================
static std::mt19937 &rng() {
    static std::mt19937 g{std::random_device{}()};
    return g;
}
// inclusive [lo, hi]
static int randIncl(int lo, int hi) {
    if (hi < lo) std::swap(lo, hi);
    std::uniform_int_distribution<int> d(lo, hi);
    return d(rng());
}
// .NET Next(0,n) == [0, n-1]
static int randExcl(int n) { return n <= 0 ? 0 : randIncl(0, n - 1); }
static double rand01() { std::uniform_real_distribution<double> d(0.0, 1.0); return d(rng()); }

// ===========================================================================
// String utilities
// ===========================================================================
static std::string trim(const std::string &s) {
    size_t a = s.find_first_not_of(" \t\r\n");
    if (a == std::string::npos) return "";
    size_t b = s.find_last_not_of(" \t\r\n");
    return s.substr(a, b - a + 1);
}
static std::string trimRight(std::string s, char c) {
    while (!s.empty() && s.back() == c) s.pop_back();
    return s;
}
static std::string toLowerStr(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c){ return (char)std::tolower(c); });
    return s;
}
static std::string toUpperStr(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c){ return (char)std::toupper(c); });
    return s;
}
static std::vector<std::string> splitStr(const std::string &str, const std::string &delim) {
    std::vector<std::string> out;
    size_t start = 0, end;
    if (delim.empty()) { out.push_back(str); return out; }
    while ((end = str.find(delim, start)) != std::string::npos) {
        out.push_back(str.substr(start, end - start));
        start = end + delim.size();
    }
    out.push_back(str.substr(start));
    return out;
}
static void replaceAll(std::string &s, const std::string &f, const std::string &r) {
    if (f.empty()) return;
    size_t p = 0;
    while ((p = s.find(f, p)) != std::string::npos) { s.replace(p, f.size(), r); p += r.size(); }
}
static std::string nsToStd(NSString *s) { return s ? std::string(s.UTF8String ?: "") : std::string(); }
static NSString *stdToNs(const std::string &s) { return [NSString stringWithUTF8String:s.c_str()] ?: @""; }

// ===========================================================================
// Civil date helpers (Howard Hinnant's algorithms)
// ===========================================================================
static long daysFromCivil(int y, int m, int d) {
    y -= m <= 2;
    long era = (y >= 0 ? y : y - 399) / 400;
    unsigned yoe = (unsigned)(y - era * 400);
    unsigned doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + (long)doe - 719468;
}
static void civilFromDays(long z, int &y, int &m, int &d) {
    z += 719468;
    long era = (z >= 0 ? z : z - 146096) / 146097;
    unsigned doe = (unsigned)(z - era * 146097);
    unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    y = (int)yoe + (int)(era * 400);
    unsigned doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    unsigned mp = (5 * doy + 2) / 153;
    d = (int)(doy - (153 * mp + 2) / 5 + 1);
    m = (int)(mp + (mp < 10 ? 3 : -9));
    y += (m <= 2);
}

// Format a date/time using a .NET-style mask (case sensitive). Tokens handled:
// yyyy yy  MM M  dd d  HH H  mm m  ss s  fff ; everything else copied literally.
static std::string formatNetDate(int y, int mo, int d, int H, int Mi, int S, const std::string &mask) {
    auto two = [](int v){ char b[8]; snprintf(b, sizeof b, "%02d", v); return std::string(b); };
    auto num = [](int v){ return std::to_string(v); };
    std::string out;
    size_t i = 0, n = mask.size();
    auto runLen = [&](char c)->size_t { size_t k = 0; while (i + k < n && mask[i + k] == c) k++; return k; };
    while (i < n) {
        char c = mask[i];
        size_t k = runLen(c);
        switch (c) {
            case 'y':
                if (k >= 4)      out += [&]{ char b[8]; snprintf(b, sizeof b, "%04d", y); return std::string(b); }();
                else if (k == 2) out += two(y % 100);
                else             out += num(y);
                i += k; break;
            case 'M': out += (k >= 2 ? two(mo) : num(mo)); i += k; break;
            case 'd': out += (k >= 2 ? two(d)  : num(d));  i += k; break;
            case 'H': out += (k >= 2 ? two(H)  : num(H));  i += k; break;
            case 'm': out += (k >= 2 ? two(Mi) : num(Mi)); i += k; break;
            case 's': out += (k >= 2 ? two(S)  : num(S));  i += k; break;
            case 'f': out += std::string(k, '0'); i += k; break;
            default:  out += c; i += 1; break;
        }
    }
    return out;
}

// ===========================================================================
// Data types
// ===========================================================================
enum class RVType { String, Integer, Decimal, DateTime, Guid };

static RVType rvTypeFromString(std::string s) {
    s = toLowerStr(s);
    if (s == "integer" || s == "int") return RVType::Integer;
    if (s == "decimal")               return RVType::Decimal;
    if (s == "datetime" || s == "date" || s == "time") return RVType::DateTime;
    if (s == "guid")                  return RVType::Guid;
    return RVType::String;
}
// Case option index <-> name (0=(none),1=lower,2=upper,3=mixed,4=initcap)
static const char *kCaseNames[] = { "(none)", "lower", "upper", "mixed", "initcap" };

// ===========================================================================
// RandomValue — port of RandomValue.cs
// ===========================================================================
class RandomValue {
public:
    std::string Description = "test";
    RVType DataType = RVType::String;
    std::string Mask;
    bool MixMask = false;
    bool PwSafe = false;
    int CaseChar = 0;
    std::string Range;
    bool RangeMinMax = false;
    int RangeIntMin = 10, RangeIntMax = 99;
    double RangeDblMin = 10.0, RangeDblMax = 99.9;
    long RangeDateMinDays = 0;
    bool RangeInclTime = false;
    int EmptyPerc = 0;
    int Width = 50;
    int _width = 0;
    int FloatDec = 1;
    std::string DecimalSep = ".";
    std::string Options;
    bool hasListRange = false;
    std::vector<std::string> ListRange;

    RandomValue() { initialise("ValueName", "String", "", "", ""); }
    explicit RandomValue(const std::string &spec) { deSerialise(spec); }
    RandomValue(const std::string &name, const std::string &type, const std::string &mask,
                const std::string &range, const std::string &options) {
        initialise(name, type, mask, range, options);
    }

    // Serialise the options back into the "k=v,k=v" form (for the Options grid cell).
    std::string optionsAsString() const {
        std::string res;
        if (_width > 0)                       res += "width=" + std::to_string(_width) + ",";
        if (EmptyPerc > 0)                    res += "empty=" + std::to_string(EmptyPerc) + ",";
        if (CaseChar > 0 && CaseChar <= 4)    res += std::string("case=") + kCaseNames[CaseChar] + ",";
        if (MixMask)                          res += "mixmask=true,";
        if (PwSafe)                           res += "pwsafe=true,";
        return trimRight(res, ',');
    }

    std::string nextValue() {
        if (EmptyPerc > 0 && randIncl(1, 100) <= EmptyPerc) return "";
        switch (DataType) {
            case RVType::String:   return getRandomVarchar();
            case RVType::Integer:  return std::to_string(RangeIntMin + randExcl(RangeIntMax - RangeIntMin + 1));
            case RVType::Decimal:  return getRandomDecimal();
            case RVType::DateTime: return getRandomDate();
            case RVType::Guid:     return getRandomGUID();
        }
        return "";
    }

private:
    // mask character sets
    static const std::string MASK_A, MASK_B, MASK_0, MASK_F, MASK_S, MASK_X, MASK_Y, MASK_Z;
    static const std::string PW_A, PW_B, PW_0, PW_X, PW_Y, PW_Z;

    void initialise(const std::string &name, const std::string &type,
                    std::string mask, std::string range, std::string options) {
        Description = name;
        DataType = rvTypeFromString(type);
        Mask = mask;
        Range = range;
        Options = options;

        if (Range.find("...") != std::string::npos) replaceAll(Range, "...", "..");
        if (DataType == RVType::Integer || DataType == RVType::Decimal) Mask = "";

        if (Range.empty()) {
            if (DataType == RVType::Integer) Range = "10..99";
            if (DataType == RVType::Decimal) Range = "10.0..99.9";
            if (DataType == RVType::DateTime) {
                int yr = currentYear();
                Range = std::to_string(yr - 1) + ".." + std::to_string(yr);
            }
        }

        if (!Range.empty()) {
            // strip {} and optional trailing operator (parsed, currently unused like Windows)
            auto pos = Range.find('}');
            if (pos != std::string::npos) {
                if (pos < Range.size() - 1) Range = Range.substr(pos);
                Range = Range.substr(1, Range.size() - 2);
            }
            RangeMinMax = (Range.find("..") != std::string::npos);
            std::string sep = RangeMinMax ? ".." : ",";
            ListRange = splitStr(Range, sep);
            hasListRange = true;

            if (RangeMinMax && DataType == RVType::Integer) {
                bool ok1 = parseInt(ListRange[0], RangeIntMin);
                bool ok2 = ListRange.size() > 1 && parseInt(ListRange[1], RangeIntMax);
                if (!ok1 || !ok2) { RangeIntMin = 10; RangeIntMax = 99; }
                if (RangeIntMin > RangeIntMax) std::swap(RangeIntMin, RangeIntMax);
            }
            if (RangeMinMax && DataType == RVType::Decimal) {
                size_t p1 = ListRange[0].find_last_of('.');
                size_t p2 = ListRange[0].find_last_of(',');
                bool dotIsSep = (p1 != std::string::npos && (p2 == std::string::npos || p1 > p2)) ||
                                (p1 == std::string::npos && p2 == std::string::npos);
                DecimalSep = dotIsSep ? "." : ",";
                bool ok1 = parseDouble(ListRange[0], RangeDblMin);
                bool ok2 = ListRange.size() > 1 && parseDouble(ListRange[1], RangeDblMax);
                if (!ok1 || !ok2) { RangeDblMin = 10.0; RangeDblMax = 99.9; DecimalSep = "."; }
                if (RangeDblMin > RangeDblMax) std::swap(RangeDblMin, RangeDblMax);
                size_t dec = ListRange[0].find(DecimalSep);
                FloatDec = (dec != std::string::npos) ? (int)(ListRange[0].size() - dec - 1) : 0;
                Width = (int)std::max(ListRange[0].size(), ListRange.size() > 1 ? ListRange[1].size() : 0);
            }
            if (RangeMinMax && DataType == RVType::DateTime) {
                if (Mask.empty()) Mask = "yyyy-MM-dd";
                long d1 = dateRangeValue(ListRange[0], false);
                long d2 = ListRange.size() > 1 ? dateRangeValue(ListRange[1], true) : d1;
                if (d1 > d2) std::swap(d1, d2);
                RangeDateMinDays = d1;
                RangeIntMax = (int)(d2 - d1);
                RangeInclTime = (Mask.find("HH") != std::string::npos ||
                                 Mask.find(":mm") != std::string::npos ||
                                 Mask.find(":ss") != std::string::npos);
            }
        }

        if (!Options.empty()) parseOptions(Options);
    }

    void parseOptions(const std::string &opts) {
        std::map<std::string, std::string> dict;
        for (auto &kv : splitStr(opts, ",")) {
            auto eq = kv.find('=');
            if (eq == std::string::npos) continue;
            dict[trim(kv.substr(0, eq))] = trim(kv.substr(eq + 1));
        }
        if (dict.count("width")) { int w; if (parseInt(dict["width"], w)) { _width = w; Width = w; } }
        std::string cas = toLowerStr(dict.count("case") ? dict["case"] : "");
        CaseChar = 0;
        for (int i = 0; i < 5; ++i) if (cas == kCaseNames[i]) CaseChar = i;
        if (dict.count("empty")) { int e; if (parseInt(dict["empty"], e)) EmptyPerc = e; }
        if (EmptyPerc < 0 || EmptyPerc >= 100) EmptyPerc = 0;
        MixMask = dict.count("mixmask") && dict["mixmask"] == "true";
        PwSafe  = dict.count("pwsafe")  && dict["pwsafe"]  == "true";
    }

    void deSerialise(const std::string &spec) {
        // "Description" type(mask) range [options]
        std::string s = spec;
        std::string name, type, mask, range, options;
        // description in quotes
        size_t q1 = s.find('"');
        size_t q2 = (q1 == std::string::npos) ? std::string::npos : s.find('"', q1 + 1);
        if (q1 == std::string::npos || q2 == std::string::npos) { initialise("Value Description", "string", "", "", ""); return; }
        name = s.substr(q1 + 1, q2 - q1 - 1);
        std::string rest = trim(s.substr(q2 + 1));
        // options [..] at end
        size_t ob = rest.find('[');
        if (ob != std::string::npos) {
            size_t cb = rest.rfind(']');
            if (cb != std::string::npos && cb > ob) options = rest.substr(ob + 1, cb - ob - 1);
            rest = trim(rest.substr(0, ob));
        }
        // type token
        size_t sp = rest.find_first_of(" (\t");
        if (sp == std::string::npos) { type = rest; rest = ""; }
        else { type = rest.substr(0, sp); rest = rest.substr(sp); }
        // mask in (...)
        size_t pp = rest.find('(');
        if (pp != std::string::npos) {
            size_t pc = rest.find(')', pp);
            if (pc != std::string::npos) { mask = rest.substr(pp + 1, pc - pp - 1); rest = rest.substr(0, pp) + rest.substr(pc + 1); }
        }
        range = trim(rest);
        initialise(name, type, trim(mask), range, options);
    }

    static int currentYear() {
        time_t t = time(nullptr); struct tm lt; localtime_r(&t, &lt); return lt.tm_year + 1900;
    }
    static bool parseInt(const std::string &s, int &out) {
        try { size_t idx; int v = std::stoi(trim(s), &idx); out = v; return true; } catch (...) { return false; }
    }
    bool parseDouble(const std::string &s, double &out) {
        std::string t = trim(s);
        if (DecimalSep == ",") replaceAll(t, ",", ".");
        try { out = std::stod(t); return true; } catch (...) { return false; }
    }

    // returns days-from-civil-epoch; "max" applies up-to-and-including semantics
    long dateRangeValue(std::string dt, bool max) {
        dt = trim(dt);
        if (dt.size() < 4) {
            std::string cent = std::to_string(currentYear()).substr(0, 2);
            dt = cent + dt;
            if (dt.size() > 4) dt = dt.substr(dt.size() - 4);
        }
        int addDay = (max && dt.size() > 7) ? 1 : 0;
        int addMonth = (max && dt.size() > 4 && dt.size() <= 7) ? 1 : 0;
        int addYear = (max && dt.size() == 4) ? 1 : 0;
        std::string full = dt + (dt.size() > 4 ? (dt.size() > 7 ? "" : "-01") : "-01-01");
        int y = 1970, m = 1, d = 1;
        if (sscanf(full.c_str(), "%d-%d-%d", &y, &m, &d) < 1) { y = 1970; m = 1; d = 1; }
        y += addYear; m += addMonth; // normalise month overflow
        while (m > 12) { m -= 12; y++; }
        long base = daysFromCivil(y, m, d) + addDay;
        return base;
    }

    std::string getRandomVarchar() {
        std::string res;
        if (!Mask.empty())          res = getRandomMaskValue();
        else if (hasListRange)      res = ListRange[randExcl((int)ListRange.size())];
        else                        res = getRandomLorem();
        if (CaseChar > 0) res = adjustCase(res);
        return res;
    }
    std::string getRandomDecimal() {
        double v = rand01() * (RangeDblMax - RangeDblMin) + RangeDblMin;
        char buf[64];
        snprintf(buf, sizeof buf, "%.*f", std::max(0, FloatDec), v);
        std::string s(buf);
        if (DecimalSep != ".") replaceAll(s, ".", DecimalSep);
        return s;
    }
    std::string getRandomDate() {
        long days = RangeDateMinDays + randExcl(RangeIntMax + 1);
        int y, m, d; civilFromDays(days, y, m, d);
        int H = 0, Mi = 0, S = 0;
        if (RangeInclTime) { int secs = randExcl(24 * 60 * 60); H = secs / 3600; Mi = (secs % 3600) / 60; S = secs % 60; }
        return formatNetDate(y, m, d, H, Mi, S, Mask);
    }
    std::string getRandomGUID() {
        std::string res;
        static const char *hex = "0123456789abcdef";
        for (int i = 0; i < 32; ++i) {
            int b = randExcl(16);
            if (i == 8 || i == 12 || i == 16 || i == 20) res += "-";
            b = (i == 12 ? 4 : (i == 16 ? ((b & 3) | 8) : b));
            res += hex[b & 0xF];
        }
        if (CaseChar > 0) res = adjustCase(res);
        return res;
    }
    std::string getRandomLorem();
    void randomizeMask() {
        // Fisher-Yates shuffle of mask characters
        for (int i = (int)Mask.size(); i-- > 1;) {
            int j = randExcl(i + 1);
            if (i != j) std::swap(Mask[i], Mask[j]);
        }
    }
    std::string getRandomMaskValue() {
        std::string res;
        if (MixMask) randomizeMask();
        for (char ch : Mask) {
            const std::string *set = nullptr;
            switch (ch) {
                case 'A': set = PwSafe ? &PW_A : &MASK_A; break;
                case 'B': set = PwSafe ? &PW_B : &MASK_B; break;
                case '9': set = PwSafe ? &PW_0 : &MASK_0; break;
                case 'F': set = &MASK_F; break;
                case '@': set = &MASK_S; break;
                case 'X': set = PwSafe ? &PW_X : &MASK_X; break;
                case 'Y': set = PwSafe ? &PW_Y : &MASK_Y; break;
                case 'Z': set = PwSafe ? &PW_Z : &MASK_Z; break;
                default:  res += ch; break;
            }
            if (set && !set->empty()) res += (*set)[randExcl((int)set->size())];
        }
        return res;
    }
    std::string adjustCase(std::string in) {
        if (CaseChar == 1) return toLowerStr(in);
        if (CaseChar == 2) return toUpperStr(in);
        std::string res;
        in = toLowerStr(in);
        bool prevspc = true;
        for (char ch : in) {
            bool upper;
            if (CaseChar == 3) upper = (randIncl(1, 100) <= 25);
            else { upper = prevspc; prevspc = (ch == ' ' || ch == '.' || ch == ','); }
            res += upper ? (char)std::toupper((unsigned char)ch) : ch;
        }
        return res;
    }
};

const std::string RandomValue::MASK_A = "AEIOU";
const std::string RandomValue::MASK_B = "BCDFGHJKLMNPQRSTVWXYZ";
const std::string RandomValue::MASK_0 = "0123456789";
const std::string RandomValue::MASK_F = "0123456789ABCDEF";
const std::string RandomValue::MASK_S = "!@#$%^&*+-";
const std::string RandomValue::MASK_X = RandomValue::MASK_A + RandomValue::MASK_B;
const std::string RandomValue::MASK_Y = RandomValue::MASK_A + RandomValue::MASK_B + RandomValue::MASK_0;
const std::string RandomValue::MASK_Z = RandomValue::MASK_A + RandomValue::MASK_B + RandomValue::MASK_0 + RandomValue::MASK_S;
const std::string RandomValue::PW_A = "aeu";
const std::string RandomValue::PW_B = "bcdfhjkmnpqrtvwxy";
const std::string RandomValue::PW_0 = "34678";
const std::string RandomValue::PW_X = RandomValue::PW_A + RandomValue::PW_B;
const std::string RandomValue::PW_Y = RandomValue::PW_A + RandomValue::PW_B + RandomValue::PW_0;
const std::string RandomValue::PW_Z = RandomValue::PW_A + RandomValue::PW_B + RandomValue::PW_0 + RandomValue::MASK_S;

static const char *kLorem =
    "Lorem ipsum dolor sit amet, consectetuer adipiscing elit. Aenean commodo ligula eget dolor. "
    "Aenean massa. Cum sociis natoque penatibus et magnis dis parturient montes, nascetur ridiculus mus. "
    "Donec quam felis, ultricies nec, pellentesque eu, pretium quis, sem. Nulla consequat massa quis enim. "
    "Donec pede justo, fringilla vel, aliquet nec, vulputate eget, arcu. In enim justo, rhoncus ut, "
    "imperdiet a, venenatis vitae, justo. Nullam dictum felis eu pede mollis pretium. Integer tincidunt. "
    "Cras dapibus. Vivamus elementum semper nisi. Aenean vulputate eleifend tellus.";

std::string RandomValue::getRandomLorem() {
    static std::vector<std::string> words = splitStr(kLorem, " ");
    std::string res;
    int x = randExcl((int)words.size());
    int i = x;
    int maxLen = randIncl(10, std::max(11, Width));
    while ((int)res.size() < maxLen && i < (int)words.size()) { res += words[i] + " "; i++; }
    res = trim(res);
    return (int)res.size() <= Width ? res : res.substr(0, Width);
}

// ===========================================================================
// Settings model (mirrors Windows keys + INI sections)
// ===========================================================================
struct Settings {
    bool LineFeed = true;
    bool ToolbarRepeatLast = true;
    std::string MenuItem1 = "\"Password (strong)\" string(XXXXYYYYZZZZ9999) [case=mixed,mixmask=true,pwsafe=true]";
    std::string MenuItem2 = "\"Password (easy)\" string(BABABA99) [case=lower,pwsafe=true]";
    std::string MenuItem3 = "\"Random guid\" guid";
    std::string MenuItem4 = "\"Dice throw\" integer {1..6}";
    std::string MenuItem5 = "\"Random color value\" string(#FFFFFF)";
    int AutoSyntaxLimit = 1024 * 1024;
    int SQLtype = 0;
    std::string GenerateTablename = "Tablename";
    int GenerateBatch = 1000;
    int GenerateType = 1;
    int GenerateAmount = 100;
    std::string GenerateCol[30] = {
        "\"Order ID\" integer {1001..9999}",
        "\"Order date\" datetime(dd-MM-yyyy) {2023..2024}",
        "\"Order price\" decimal {10.0..99.9}",
        "\"Parts group\" string {ENGINE,ELECTRA,CARBODY,CHASSIS,INTERIO,CLIMATE}",
        "\"Order description\" string [width=15]",
    };
};
static Settings g_settings;
static int g_repeatLast = 1;
static RandomValue g_menuRnd[5];

// ---- INI path / load / save ----
static std::string iniPath() {
    char buf[1024] = {0};
    npp(NPPM_GETPLUGINSCONFIGDIR, sizeof(buf), (intptr_t)buf);
    std::string dir = buf[0] ? buf : (nsToStd(NSHomeDirectory()) + "/.nextpad++/plugins/Config");
    return dir + "/Random values.ini";
}
static void loadSettings() {
    @autoreleasepool {
        NSString *path = stdToNs(iniPath());
        NSError *err = nil;
        NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&err];
        if (!content) return;
        std::map<std::string, std::string> kv;
        for (NSString *raw in [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
            std::string line = trim(nsToStd(raw));
            if (line.empty() || line[0] == ';' || line[0] == '[') continue;
            auto eq = line.find('=');
            if (eq == std::string::npos) continue;
            kv[trim(line.substr(0, eq))] = line.substr(eq + 1); // value kept verbatim (may contain spaces)
        }
        auto S = [&](const char *k, std::string &dst){ auto it = kv.find(k); if (it != kv.end()) dst = it->second; };
        auto B = [&](const char *k, bool &dst){ auto it = kv.find(k); if (it != kv.end()) dst = (toLowerStr(trim(it->second)) == "true" || trim(it->second) == "1"); };
        auto Iint = [&](const char *k, int &dst){ auto it = kv.find(k); if (it != kv.end()) { try { dst = std::stoi(trim(it->second)); } catch (...) {} } };
        B("LineFeed", g_settings.LineFeed);
        B("ToolbarRepeatLast", g_settings.ToolbarRepeatLast);
        S("MenuItem1", g_settings.MenuItem1); S("MenuItem2", g_settings.MenuItem2);
        S("MenuItem3", g_settings.MenuItem3); S("MenuItem4", g_settings.MenuItem4);
        S("MenuItem5", g_settings.MenuItem5);
        Iint("AutoSyntaxLimit", g_settings.AutoSyntaxLimit);
        Iint("SQLtype", g_settings.SQLtype);
        S("GenerateTablename", g_settings.GenerateTablename);
        Iint("GenerateBatch", g_settings.GenerateBatch);
        if (g_settings.GenerateBatch < 10) g_settings.GenerateBatch = 10;
        Iint("GenerateType", g_settings.GenerateType);
        Iint("GenerateAmount", g_settings.GenerateAmount);
        for (int i = 0; i < 30; ++i) {
            char key[32]; snprintf(key, sizeof key, "GenerateCol%02d", i + 1);
            S(key, g_settings.GenerateCol[i]);
        }
    }
}
static void saveSettings() {
    @autoreleasepool {
        std::ostringstream o;
        o << "; " << PLUGIN_NAME << " settings file\n";
        o << "\n[General]\n";
        o << "LineFeed=" << (g_settings.LineFeed ? "True" : "False") << "\n";
        o << "ToolbarRepeatLast=" << (g_settings.ToolbarRepeatLast ? "True" : "False") << "\n";
        o << "\n[Menu items]\n";
        o << "MenuItem1=" << g_settings.MenuItem1 << "\n";
        o << "MenuItem2=" << g_settings.MenuItem2 << "\n";
        o << "MenuItem3=" << g_settings.MenuItem3 << "\n";
        o << "MenuItem4=" << g_settings.MenuItem4 << "\n";
        o << "MenuItem5=" << g_settings.MenuItem5 << "\n";
        o << "\n[RandomGenerate]\n";
        o << "AutoSyntaxLimit=" << g_settings.AutoSyntaxLimit << "\n";
        o << "GenerateAmount=" << g_settings.GenerateAmount << "\n";
        o << "GenerateBatch=" << g_settings.GenerateBatch << "\n";
        o << "GenerateTablename=" << g_settings.GenerateTablename << "\n";
        o << "GenerateType=" << g_settings.GenerateType << "\n";
        o << "SQLtype=" << g_settings.SQLtype << "\n";
        o << "\n[RandomGenerateCols]\n";
        for (int i = 0; i < 30; ++i) {
            char key[32]; snprintf(key, sizeof key, "GenerateCol%02d", i + 1);
            o << key << "=" << g_settings.GenerateCol[i] << "\n";
        }
        NSString *path = stdToNs(iniPath());
        [stdToNs(o.str()) writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

// ===========================================================================
// Output generators (CSV / SQL / XML / JSON) — port of RandomValues.cs
// ===========================================================================
static std::vector<RandomValue> generateColumns() {
    std::vector<RandomValue> list;
    for (int i = 0; i < 30; ++i)
        if (!g_settings.GenerateCol[i].empty()) list.emplace_back(g_settings.GenerateCol[i]);
    return list;
}
static std::vector<std::string> scriptInfo(int amount) {
    @autoreleasepool {
        std::vector<std::string> v;
        v.push_back("Notepad++ Random Values plug-in: v1.0 (macOS)");
        v.push_back("Generate records: " + std::to_string(amount));
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"dd-MMM-yyyy HH:mm";
        v.push_back("Date: " + nsToStd([df stringFromDate:[NSDate date]]));
        return v;
    }
}
static void genCSV(std::ostringstream &sb, std::vector<RandomValue> &list, int amount, char sep) {
    for (size_t r = 0; r < list.size(); ++r) {
        if (r > 0) sb << sep;
        std::string v = list[r].Description;
        if (v.find(sep) != std::string::npos) v = "\"" + v + "\"";
        sb << v;
    }
    sb << "\r\n";
    for (int i = 0; i < amount; ++i) {
        for (size_t r = 0; r < list.size(); ++r) {
            if (r > 0) sb << sep;
            std::string v = list[r].nextValue();
            if (v.find(sep) != std::string::npos) v = "\"" + v + "\"";
            sb << v;
        }
        sb << "\r\n";
    }
}
static std::string sqlSafeName(const std::string &name) {
    if (name.find(' ') != std::string::npos || name.find('\'') != std::string::npos) {
        if (g_settings.SQLtype == 1) return "[" + name + "]";
        std::string q = (g_settings.SQLtype == 0) ? "`" : "\"";
        return q + name + q;
    }
    return name;
}
static void genSQL(std::ostringstream &sb, std::vector<RandomValue> &list, int amount) {
    const std::string TABLE = g_settings.GenerateTablename;
    const std::string recid = "_record_number";
    std::string sqltypeName = (g_settings.SQLtype <= 1 ? (g_settings.SQLtype == 0 ? "mySQL" : "MS-SQL") : "PostgreSQL");

    sb << "-- -------------------------------------\r\n";
    auto comment = scriptInfo(amount);
    for (auto &c : comment) sb << "-- " << c << "\r\n";
    sb << "-- SQL type: " << sqltypeName << "\r\n";
    sb << "-- -------------------------------------\r\n";
    sb << "CREATE TABLE " << TABLE << "(\r\n\t";
    switch (g_settings.SQLtype) {
        case 1: sb << "[" << recid << "] int IDENTITY(1,1) PRIMARY KEY,\r\n\t"; break;
        case 2: sb << "\"" << recid << "\" SERIAL PRIMARY KEY,\r\n\t"; break;
        default: sb << "`" << recid << "` int AUTO_INCREMENT NOT NULL,\r\n\t"; break;
    }
    std::string cols = "\t", enumcols1, enumcols2;
    for (size_t r = 0; r < list.size(); ++r) {
        std::string name = sqlSafeName(list[r].Description);
        std::string sqltype = "varchar";
        if (list[r].DataType == RVType::Integer) sqltype = "integer";
        if (list[r].DataType == RVType::DateTime) sqltype = (g_settings.SQLtype < 2 ? "datetime" : "timestamp");
        if (list[r].DataType == RVType::Guid) sqltype = "varchar(36)";
        if (list[r].DataType == RVType::Decimal) sqltype = "numeric(" + std::to_string(list[r].Width) + "," + std::to_string(list[r].FloatDec) + ")";
        if (list[r].DataType == RVType::String) sqltype = "varchar(" + std::to_string(list[r].Width) + ")";
        if (list[r].DataType == RVType::Decimal) list[r].DecimalSep = ".";
        if (list[r].DataType == RVType::DateTime) {
            std::string mn;
            if (list[r].Mask.find("yy") != std::string::npos) mn += "yyyy-MM-dd";
            if (list[r].Mask.find("H") != std::string::npos) mn += " HH:mm";
            if (list[r].Mask.find("s") != std::string::npos) mn += ":ss";
            if (list[r].Mask.find("f") != std::string::npos) mn += ".fff";
            list[r].Mask = trim(mn);
        }
        // enum columns
        if (list[r].DataType == RVType::String && list[r].hasListRange && !list[r].RangeMinMax) {
            // distinct values
            std::vector<std::string> distinct;
            for (auto &v : list[r].ListRange) if (std::find(distinct.begin(), distinct.end(), v) == distinct.end()) distinct.push_back(v);
            std::string joined;
            for (size_t k = 0; k < distinct.size(); ++k) { if (k) joined += "\", \""; joined += distinct[k]; }
            replaceAll(joined, "'", "''");
            switch (g_settings.SQLtype) {
                case 1: {
                    std::string chk = sqlSafeName("CHK_" + list[r].Description);
                    std::string ev = "'" + joined + "'"; replaceAll(ev, "\"", "'");
                    enumcols1 += "ALTER TABLE " + TABLE + " ADD CONSTRAINT " + chk + " CHECK(" + name + " COLLATE Latin1_General_CS_AS IN (" + ev + "));\r\n";
                    break;
                }
                case 2: {
                    std::string pe = sqlSafeName("enum_" + list[r].Description);
                    std::string ev = joined; replaceAll(ev, "\"", "'");
                    enumcols1 += "CREATE TYPE " + pe + " AS ENUM ('" + ev + "');\r\n";
                    enumcols2 += "ALTER TABLE " + TABLE + " ALTER COLUMN " + name + " TYPE " + pe + " USING (" + name + "::text)::" + pe + ";\r\n";
                    break;
                }
                default: {
                    std::string ev = joined; replaceAll(ev, "\"", "'");
                    enumcols1 += "ALTER TABLE " + TABLE + " MODIFY COLUMN " + name + " ENUM('" + ev + "');\r\n";
                    break;
                }
            }
        }
        sb << name << " " << sqltype;
        cols += name;
        if (r < list.size() - 1) { sb << ",\r\n\t"; cols += ",\r\n\t"; }
    }
    if (g_settings.SQLtype == 0) sb << ",\r\n\tprimary key(`" << recid << "`)";
    sb << "\r\n);\r\n";
    if (!enumcols1.empty()) sb << "-- Enumeration columns (optional)\r\n/*\r\n" << enumcols1 << enumcols2 << "*/\r\n";

    std::string tabcomment;
    for (size_t k = 0; k < comment.size(); ++k) { if (k) tabcomment += "\r\n"; tabcomment += comment[k]; }
    replaceAll(tabcomment, "'", "''");
    sb << "-- Table comment\r\n";
    switch (g_settings.SQLtype) {
        case 1: sb << "EXEC sp_addextendedproperty 'Comment', N'" << tabcomment << "', N'SCHEMA', DBO, N'TABLE', " << TABLE << "\r\nGO\r\n"; break;
        case 2: sb << "COMMENT ON TABLE " << TABLE << " IS '" << tabcomment << "';\r\n"; break;
        default: sb << "ALTER TABLE " << TABLE << " COMMENT '" << tabcomment << "';\r\n"; break;
    }

    int maxrec = 0, batch = std::max(10, g_settings.GenerateBatch);
    for (int i = 0; i < amount; ++i) {
        if (i % batch == 0) {
            maxrec = std::min(i + batch, amount);
            sb << "\r\n-- -------------------------------------\r\n";
            sb << "-- insert records " << (i + 1) << " - " << maxrec << "\r\n";
            sb << "-- -------------------------------------\r\n";
            sb << "INSERT INTO " << TABLE << "(\r\n" << cols << "\r\n) VALUES";
        }
        sb << "\r\n(";
        for (size_t r = 0; r < list.size(); ++r) {
            if (r > 0) sb << ", ";
            std::string str = list[r].nextValue();
            if (str.empty()) str = "NULL";
            else if (list[r].DataType == RVType::String || list[r].DataType == RVType::DateTime || list[r].DataType == RVType::Guid)
                str = "'" + str + "'";
            sb << str;
        }
        sb << ")";
        sb << (i < maxrec - 1 ? "," : ";\r\n\r\n");
    }
}
static std::string validXmlTag(const std::string &key) {
    std::string t;
    for (char ch : key) t += (isalnum((unsigned char)ch) || ch == '_' || ch == '-' || ch == '.') ? ch : ' ';
    // collapse spaces -> underscore
    std::string out; bool prevSpace = false;
    for (char ch : t) { if (ch == ' ') { if (!prevSpace && !out.empty()) out += '_'; prevSpace = true; } else { out += ch; prevSpace = false; } }
    out = trimRight(out, '_');
    if (out.empty() || isdigit((unsigned char)out[0]) || out[0] == '-' || out[0] == '.') out = "_" + out;
    return out;
}
static std::string xmlEscape(std::string v) { replaceAll(v, "&", "&amp;"); replaceAll(v, ">", "&gt;"); replaceAll(v, "<", "&lt;"); return v; }
static void genXML(std::ostringstream &sb, std::vector<RandomValue> &list, int amount) {
    for (auto &c : list) c.Description = validXmlTag(c.Description);
    sb << "<RandomValues>\r\n\t<!--\r\n";
    for (auto &c : scriptInfo(amount)) sb << "\t" << c << "\r\n";
    sb << "\t-->\r\n";
    for (int i = 0; i < amount; ++i) {
        sb << "\t<" << g_settings.GenerateTablename << ">\r\n";
        for (auto &col : list) {
            std::string v = xmlEscape(col.nextValue());
            if (v.empty()) sb << "\t\t<" << col.Description << "/>\r\n";
            else sb << "\t\t<" << col.Description << ">" << v << "</" << col.Description << ">\r\n";
        }
        sb << "\t</" << g_settings.GenerateTablename << ">\r\n";
    }
    sb << "</RandomValues>\r\n";
}
static void genJSON(std::ostringstream &sb, std::vector<RandomValue> &list, int amount) {
    for (auto &c : list) { c.DecimalSep = "."; replaceAll(c.Description, "\"", "\\\""); }
    sb << "{\r\n";
    for (auto &c : scriptInfo(amount)) { std::string s = c; replaceAll(s, ": ", "\": \""); sb << "\t\"" << s << "\",\r\n"; }
    sb << "\t\"" << g_settings.GenerateTablename << "\":[\r\n";
    for (int i = 0; i < amount; ++i) {
        sb << "\t\t{";
        for (size_t r = 0; r < list.size(); ++r) {
            std::string str = list[r].nextValue(); replaceAll(str, "\"", "\\\"");
            if (str.empty() || (list[r].DataType != RVType::Decimal && list[r].DataType != RVType::Integer)) str = "\"" + str + "\"";
            sb << "\r\n\t\t\t\"" << list[r].Description << "\": " << str;
            if (r < list.size() - 1) sb << ",";
        }
        sb << "\r\n\t\t}";
        if (i < amount - 1) sb << ",";
        sb << "\r\n";
    }
    sb << "\t]\r\n}\r\n";
}
static std::string generateOutput() {
    auto list = generateColumns();
    std::ostringstream sb;
    switch (g_settings.GenerateType) {
        case 0: genCSV(sb, list, g_settings.GenerateAmount, ','); break;
        case 1: genCSV(sb, list, g_settings.GenerateAmount, '\t'); break;
        case 2: genCSV(sb, list, g_settings.GenerateAmount, ';'); break;
        case 3: genSQL(sb, list, g_settings.GenerateAmount); break;
        case 4: genXML(sb, list, g_settings.GenerateAmount); break;
        case 5: genJSON(sb, list, g_settings.GenerateAmount); break;
        default: genCSV(sb, list, g_settings.GenerateAmount, '\t'); break;
    }
    return sb.str();
}

// Open the generated text in a new document, applying syntax highlighting.
// `text` is taken by value so the async block owns a valid copy (capturing a
// reference would dangle once the caller's local string is destroyed).
static void emitToNewFile(std::string text) {
    npp(NPPM_MENUCOMMAND, 0, 41001); // IDM_FILE_NEW (host maps to newDocument:)
    int type = g_settings.GenerateType;
    size_t len = text.size();
    int autolimit = g_settings.AutoSyntaxLimit;
    dispatch_async(dispatch_get_main_queue(), ^{
        NppHandle h = curSci();
        nppData._sendMessage(h, SCI_SETTEXT, 0, (intptr_t)text.c_str());
        if ((int)len < autolimit) {
            int lang = -1;
            if (type == 3) lang = 31;      // L_SQL
            else if (type == 4) lang = 9;  // L_XML
            else if (type == 5) lang = 51; // L_JSON (canonical NPP id)
            if (lang >= 0) nppData._sendMessage(nppData._nppHandle, NPPM_SETCURRENTLANGTYPE, 0, lang);
        }
    });
}

// ===========================================================================
// Forward declarations for window controllers (defined below)
// ===========================================================================
static void showSettingsWindow();
static void showGenerateWindow();
static void showAboutDialog();
static void rebuildMenuItems();

// ===========================================================================
// Menu actions
// ===========================================================================
static void insertRandomValue(RandomValue &rnd) {
    std::string s = rnd.nextValue();
    if (g_settings.LineFeed) s += sciEOL();
    sciReplaceSel(s);
}
static void cmdItem1() { insertRandomValue(g_menuRnd[0]); g_repeatLast = 1; }
static void cmdItem2() { insertRandomValue(g_menuRnd[1]); g_repeatLast = 2; }
static void cmdItem3() { insertRandomValue(g_menuRnd[2]); g_repeatLast = 3; }
static void cmdItem4() { insertRandomValue(g_menuRnd[3]); g_repeatLast = 4; }
static void cmdItem5() { insertRandomValue(g_menuRnd[4]); g_repeatLast = 5; }
static void cmdRepeat() {
    int i = (g_repeatLast >= 1 && g_repeatLast <= 5) ? g_repeatLast : 1;
    insertRandomValue(g_menuRnd[i - 1]);
}
static void cmdGenerate() { showGenerateWindow(); }
static void cmdSettings() { showSettingsWindow(); }
static void cmdAbout()    { showAboutDialog(); }

// ===========================================================================
// About dialog
// ===========================================================================
static void showAboutDialog() {
    @autoreleasepool {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"Random Values";
        a.informativeText =
            @"Version 1.0 (macOS port)\n\n"
            "Generate passwords, GUIDs, dice throws, colors, and bulk test data "
            "(CSV, SQL, XML, JSON) using a configurable random-value spec language.\n\n"
            "Original Windows plugin by Bas de Reuver (BdR76).\n"
            "macOS port for Nextpad++.";
        NSString *iconPath = [[NSBundle bundleForClass:[NSApplication class]] bundlePath]; (void)iconPath;
        [a addButtonWithTitle:@"Visit homepage"];
        [a addButtonWithTitle:@"OK"];
        if ([a runModal] == NSAlertFirstButtonReturn) {
            NSURL *u = [NSURL URLWithString:@"https://github.com/BdR76/RandomValuesNPP"];
            if (u) [[NSWorkspace sharedWorkspace] openURL:u];
        }
    }
}

// ===========================================================================
// Shared option lists
// ===========================================================================
static NSArray<NSString *> *kDataTypeNames() { return @[@"String", @"Integer", @"Decimal", @"DateTime", @"Guid"]; }
static NSArray<NSString *> *kOutputTypeNames() { return @[@"Comma separated (CSV)", @"Tab separated", @"Semicolon separated", @"SQL", @"XML", @"JSON"]; }
static NSArray<NSString *> *kSqlTypeNames() { return @[@"mySQL", @"MS-SQL", @"PostgreSQL"]; }
static NSArray<NSString *> *kCaseDisplayNames() { return @[@"(None)", @"lower", @"upper", @"mixed", @"initcap"]; }
static const char *typeNameForIdx(int i) {
    switch (i) { case 1: return "integer"; case 2: return "decimal"; case 3: return "datetime"; case 4: return "guid"; default: return "string"; }
}

// ===========================================================================
// Column model for the Generate grid
// ===========================================================================
@interface RVColumn : NSObject
@property(nonatomic, copy) NSString *desc;
@property(nonatomic, assign) int dataType;   // 0..4
@property(nonatomic, copy) NSString *mask;
@property(nonatomic, copy) NSString *range;
@property(nonatomic, copy) NSString *options;
@end
@implementation RVColumn @end

// ===========================================================================
// Options dialog (per-column) — modal
// ===========================================================================
@interface RVOptionsController : NSObject
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSTextField *widthField;
@property(nonatomic, strong) NSPopUpButton *casePopup;
@property(nonatomic, strong) NSButton *mixMaskCheck;
@property(nonatomic, strong) NSButton *pwSafeCheck;
@property(nonatomic, strong) NSTextField *emptyField;
@property(nonatomic, assign) NSModalResponse result;
@end

@implementation RVOptionsController

- (instancetype)init {
    if ((self = [super init])) [self build];
    return self;
}

- (void)build {
    NSRect r = NSMakeRect(0, 0, 420, 280);
    _window = [[NSWindow alloc] initWithContentRect:r
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
        backing:NSBackingStoreBuffered defer:YES];
    _window.title = @"Options";
    NSView *root = _window.contentView;

    auto label = ^NSTextField *(NSString *s, CGFloat y) {
        NSTextField *t = [NSTextField labelWithString:s];
        t.frame = NSMakeRect(20, y, 170, 20);
        [root addSubview:t];
        return t;
    };
    label(@"Maximum width", 230);
    _widthField = [[NSTextField alloc] initWithFrame:NSMakeRect(200, 228, 100, 22)];
    [root addSubview:_widthField];

    label(@"Uppercase/lowercase", 190);
    _casePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(200, 186, 190, 26)];
    [_casePopup addItemsWithTitles:kCaseDisplayNames()];
    [root addSubview:_casePopup];

    label(@"Mix mask", 150);
    _mixMaskCheck = [NSButton checkboxWithTitle:@"" target:nil action:nil];
    _mixMaskCheck.frame = NSMakeRect(200, 148, 30, 22);
    [root addSubview:_mixMaskCheck];

    label(@"Password safe chars.", 110);
    _pwSafeCheck = [NSButton checkboxWithTitle:@"" target:nil action:nil];
    _pwSafeCheck.frame = NSMakeRect(200, 108, 30, 22);
    [root addSubview:_pwSafeCheck];

    label(@"Empty percentage", 70);
    _emptyField = [[NSTextField alloc] initWithFrame:NSMakeRect(200, 68, 100, 22)];
    [root addSubview:_emptyField];

    NSButton *ok = [NSButton buttonWithTitle:@"Ok" target:self action:@selector(ok:)];
    ok.frame = NSMakeRect(300, 18, 90, 30); ok.keyEquivalent = @"\r";
    [root addSubview:ok];
    NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
    cancel.frame = NSMakeRect(200, 18, 90, 30); cancel.keyEquivalent = @"\e";
    [root addSubview:cancel];
}

- (NSString *)runModalForColumn:(RVColumn *)col {
    self.window.title = [NSString stringWithFormat:@"Options - %@", col.desc ?: @""];
    // parse current options into controls
    std::map<std::string, std::string> dict;
    for (auto &kv : splitStr(nsToStd(col.options), ",")) {
        auto eq = kv.find('=');
        if (eq != std::string::npos) dict[trim(kv.substr(0, eq))] = trim(kv.substr(eq + 1));
    }
    self.widthField.stringValue = dict.count("width") ? stdToNs(dict["width"]) : @"";
    self.emptyField.stringValue = dict.count("empty") ? stdToNs(dict["empty"]) : @"";
    std::string cas = dict.count("case") ? toLowerStr(dict["case"]) : "";
    int caseIdx = 0;
    for (int i = 0; i < 5; ++i) if (cas == kCaseNames[i]) caseIdx = i;
    [self.casePopup selectItemAtIndex:caseIdx];
    self.mixMaskCheck.state = (dict.count("mixmask") && dict["mixmask"] == "true") ? NSControlStateValueOn : NSControlStateValueOff;
    self.pwSafeCheck.state  = (dict.count("pwsafe")  && dict["pwsafe"]  == "true") ? NSControlStateValueOn : NSControlStateValueOff;

    // enable rules: mix/pwsafe only for string; case for non int/decimal
    BOOL isString = (col.dataType == 0);
    self.mixMaskCheck.enabled = isString;
    self.pwSafeCheck.enabled = isString;
    self.casePopup.enabled = (col.dataType != 1 && col.dataType != 2);

    self.result = NSModalResponseCancel;
    [NSApp runModalForWindow:self.window];
    [self.window orderOut:nil];

    if (self.result != NSModalResponseOK) return nil;

    // build options string
    std::string res;
    std::string w = trim(nsToStd(self.widthField.stringValue));
    std::string e = trim(nsToStd(self.emptyField.stringValue));
    int ci = (int)self.casePopup.indexOfSelectedItem;
    if (!w.empty()) res += "width=" + w + ",";
    if (ci > 0 && ci <= 4) res += std::string("case=") + kCaseNames[ci] + ",";
    if (self.mixMaskCheck.state == NSControlStateValueOn && isString) res += "mixmask=true,";
    if (self.pwSafeCheck.state == NSControlStateValueOn && isString) res += "pwsafe=true,";
    if (!e.empty()) res += "empty=" + e + ",";
    return stdToNs(trimRight(res, ','));
}

- (void)ok:(id)sender { self.result = NSModalResponseOK; [NSApp stopModal]; }
- (void)cancel:(id)sender { self.result = NSModalResponseCancel; [NSApp stopModal]; }
@end

// ===========================================================================
// Generate window
// ===========================================================================
@interface RVGenerateController : NSObject <NSTableViewDataSource, NSTableViewDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSTableView *table;
@property(nonatomic, strong) NSMutableArray<RVColumn *> *columns;
@property(nonatomic, strong) NSPopUpButton *outputPopup;
@property(nonatomic, strong) NSTextField *amountField;
@property(nonatomic, strong) NSStepper *amountStepper;
@property(nonatomic, strong) NSTextField *tablenameLabel;
@property(nonatomic, strong) NSTextField *tablenameField;
@property(nonatomic, strong) NSView *sqlPanel;
@property(nonatomic, strong) NSPopUpButton *sqlTypePopup;
@property(nonatomic, strong) NSTextField *batchField;
@property(nonatomic, assign) NSModalResponse result;
@property(nonatomic, assign) int addExampleIdx;
@end

@implementation RVGenerateController

- (instancetype)init { if ((self = [super init])) { [self loadColumns]; [self build]; } return self; }

- (void)loadColumns {
    self.columns = [NSMutableArray array];
    for (int i = 0; i < 30; ++i) {
        if (g_settings.GenerateCol[i].empty()) continue;
        RandomValue rv(g_settings.GenerateCol[i]);
        RVColumn *c = [RVColumn new];
        c.desc = stdToNs(rv.Description);
        c.dataType = (int)rv.DataType;
        c.mask = stdToNs(rv.Mask);
        c.range = stdToNs(rv.Range);
        c.options = stdToNs(rv.optionsAsString());
        [self.columns addObject:c];
    }
}

- (void)build {
    NSRect r = NSMakeRect(0, 0, 920, 500);
    _window = [[NSWindow alloc] initWithContentRect:r
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
        backing:NSBackingStoreBuffered defer:YES];
    _window.title = @"Generate random values";
    _window.minSize = NSMakeSize(760, 420);
    NSView *root = _window.contentView;

    // table + scroll
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 150, 820, 330)];
    scroll.hasVerticalScroller = YES; scroll.borderType = NSLineBorder;
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _table = [[NSTableView alloc] initWithFrame:scroll.bounds];
    _table.usesAlternatingRowBackgroundColors = YES;
    _table.rowHeight = 24;
    _table.dataSource = self; _table.delegate = self;

    struct { NSString *ident; NSString *title; CGFloat w; } cols[] = {
        {@"desc", @"Description", 220}, {@"type", @"Data type", 130}, {@"mask", @"Mask", 130},
        {@"range", @"Range", 230}, {@"opts", @"Options", 90}
    };
    for (auto &c : cols) {
        NSTableColumn *tc = [[NSTableColumn alloc] initWithIdentifier:c.ident];
        tc.title = c.title; tc.width = c.w; tc.minWidth = 60;
        [_table addTableColumn:tc];
    }
    scroll.documentView = _table;
    [root addSubview:scroll];

    // side buttons (up / + / trash / down)
    CGFloat bx = 848, by = 446;
    NSButton *(^sideBtn)(NSString *, SEL, CGFloat) = ^NSButton *(NSString *sym, SEL sel, CGFloat y) {
        NSButton *b = [NSButton buttonWithTitle:@"" target:self action:sel];
        NSImage *img = [NSImage imageWithSystemSymbolName:sym accessibilityDescription:nil];
        if (img) { b.image = img; b.title = @""; } else b.title = sym;
        b.frame = NSMakeRect(bx, y, 40, 30);
        b.bezelStyle = NSBezelStyleRounded;
        b.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
        [root addSubview:b];
        return b;
    };
    sideBtn(@"chevron.up", @selector(moveUp:), by);
    sideBtn(@"plus", @selector(addRow:), by - 38);
    sideBtn(@"trash", @selector(delRow:), by - 76);
    sideBtn(@"chevron.down", @selector(moveDown:), by - 114);

    // bottom controls
    NSTextField *lblOut = [NSTextField labelWithString:@"Output type"];
    lblOut.frame = NSMakeRect(16, 108, 90, 20); lblOut.autoresizingMask = NSViewMaxYMargin; [root addSubview:lblOut];
    _outputPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(110, 104, 240, 26)];
    [_outputPopup addItemsWithTitles:kOutputTypeNames()];
    _outputPopup.target = self; _outputPopup.action = @selector(outputChanged:);
    [root addSubview:_outputPopup];

    NSTextField *lblAmt = [NSTextField labelWithString:@"Amount"];
    lblAmt.frame = NSMakeRect(16, 70, 90, 20); [root addSubview:lblAmt];
    _amountField = [[NSTextField alloc] initWithFrame:NSMakeRect(110, 68, 100, 22)];
    [root addSubview:_amountField];
    _amountStepper = [[NSStepper alloc] initWithFrame:NSMakeRect(214, 66, 20, 26)];
    _amountStepper.minValue = 1; _amountStepper.maxValue = 100000000; _amountStepper.increment = 1;
    _amountStepper.target = self; _amountStepper.action = @selector(stepperChanged:);
    [root addSubview:_amountStepper];

    // tablename (cond)
    _tablenameLabel = [NSTextField labelWithString:@"Table/record name"];
    _tablenameLabel.frame = NSMakeRect(380, 108, 130, 20); [root addSubview:_tablenameLabel];
    _tablenameField = [[NSTextField alloc] initWithFrame:NSMakeRect(515, 104, 200, 22)];
    [root addSubview:_tablenameField];

    // SQL panel (cond): SQL type + batch
    _sqlPanel = [[NSView alloc] initWithFrame:NSMakeRect(380, 60, 420, 40)];
    NSTextField *lblSql = [NSTextField labelWithString:@"SQL type"];
    lblSql.frame = NSMakeRect(0, 8, 70, 20); [_sqlPanel addSubview:lblSql];
    _sqlTypePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(75, 4, 130, 26)];
    [_sqlTypePopup addItemsWithTitles:kSqlTypeNames()];
    [_sqlPanel addSubview:_sqlTypePopup];
    NSTextField *lblBatch = [NSTextField labelWithString:@"Batch"];
    lblBatch.frame = NSMakeRect(220, 8, 50, 20); [_sqlPanel addSubview:lblBatch];
    _batchField = [[NSTextField alloc] initWithFrame:NSMakeRect(270, 4, 90, 22)];
    [_sqlPanel addSubview:_batchField];
    [root addSubview:_sqlPanel];

    // Ok / Cancel
    NSButton *ok = [NSButton buttonWithTitle:@"Ok" target:self action:@selector(ok:)];
    ok.frame = NSMakeRect(826, 16, 80, 30); ok.keyEquivalent = @"\r";
    ok.autoresizingMask = NSViewMinXMargin; [root addSubview:ok];
    NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
    cancel.frame = NSMakeRect(736, 16, 80, 30); cancel.keyEquivalent = @"\e";
    cancel.autoresizingMask = NSViewMinXMargin; [root addSubview:cancel];

    // initial values
    int gt = (g_settings.GenerateType >= 0 && g_settings.GenerateType < (int)kOutputTypeNames().count) ? g_settings.GenerateType : 0;
    [_outputPopup selectItemAtIndex:gt];
    _amountField.stringValue = [NSString stringWithFormat:@"%d", g_settings.GenerateAmount];
    _amountStepper.integerValue = g_settings.GenerateAmount;
    _tablenameField.stringValue = stdToNs(g_settings.GenerateTablename);
    [_sqlTypePopup selectItemAtIndex:(g_settings.SQLtype >= 0 && g_settings.SQLtype <= 2 ? g_settings.SQLtype : 0)];
    _batchField.stringValue = [NSString stringWithFormat:@"%d", g_settings.GenerateBatch];
    [self updateConditionalControls];
}

- (void)updateConditionalControls {
    int idx = (int)self.outputPopup.indexOfSelectedItem;
    BOOL nameVisible = (idx >= 3);
    self.tablenameLabel.hidden = !nameVisible;
    self.tablenameField.hidden = !nameVisible;
    self.sqlPanel.hidden = (idx != 3);
}

// ---- table data source ----
- (NSInteger)numberOfRowsInTableView:(NSTableView *)t { return self.columns.count; }

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    RVColumn *c = self.columns[row];
    NSString *ident = col.identifier;
    if ([ident isEqualToString:@"type"]) {
        NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, col.width, 22)];
        [p addItemsWithTitles:kDataTypeNames()];
        [p selectItemAtIndex:(c.dataType >= 0 && c.dataType < 5 ? c.dataType : 0)];
        p.tag = row; p.target = self; p.action = @selector(typeChanged:);
        p.bordered = NO;
        return p;
    }
    if ([ident isEqualToString:@"opts"]) {
        NSButton *b = [NSButton buttonWithTitle:@"…" target:self action:@selector(optionsClicked:)];
        b.tag = row; b.bezelStyle = NSBezelStyleRounded;
        return b;
    }
    NSTextField *tf = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, col.width, 22)];
    tf.bordered = NO; tf.drawsBackground = NO; tf.tag = row; tf.delegate = (id<NSTextFieldDelegate>)self;
    tf.identifier = ident;
    if ([ident isEqualToString:@"desc"]) tf.stringValue = c.desc ?: @"";
    else if ([ident isEqualToString:@"mask"]) tf.stringValue = c.mask ?: @"";
    else if ([ident isEqualToString:@"range"]) tf.stringValue = c.range ?: @"";
    return tf;
}

- (void)controlTextDidEndEditing:(NSNotification *)note {
    NSTextField *tf = note.object;
    if (![tf isKindOfClass:[NSTextField class]]) return;
    NSInteger row = tf.tag;
    if (row < 0 || row >= (NSInteger)self.columns.count) return;
    RVColumn *c = self.columns[row];
    NSString *ident = tf.identifier;
    if ([ident isEqualToString:@"desc"]) c.desc = tf.stringValue;
    else if ([ident isEqualToString:@"mask"]) c.mask = tf.stringValue;
    else if ([ident isEqualToString:@"range"]) c.range = tf.stringValue;
}

- (void)typeChanged:(NSPopUpButton *)sender {
    NSInteger row = sender.tag;
    if (row >= 0 && row < (NSInteger)self.columns.count) self.columns[row].dataType = (int)sender.indexOfSelectedItem;
}

- (void)optionsClicked:(NSButton *)sender {
    NSInteger row = sender.tag;
    if (row < 0 || row >= (NSInteger)self.columns.count) return;
    RVColumn *c = self.columns[row];
    RVOptionsController *opt = [[RVOptionsController alloc] init];
    NSString *res = [opt runModalForColumn:c];
    if (res) c.options = res;
}

// ---- side buttons ----
- (void)moveUp:(id)s { [self moveBy:-1]; }
- (void)moveDown:(id)s { [self moveBy:1]; }
- (void)moveBy:(NSInteger)delta {
    NSInteger row = self.table.selectedRow;
    NSInteger to = row + delta;
    if (row < 0 || to < 0 || to >= (NSInteger)self.columns.count) return;
    [self.columns exchangeObjectAtIndex:row withObjectAtIndex:to];
    [self.table reloadData];
    [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:to] byExtendingSelection:NO];
}
- (void)addRow:(id)s {
    if (self.columns.count >= 30) return;
    int yr = 0; { time_t t = time(nullptr); struct tm lt; localtime_r(&t, &lt); yr = lt.tm_year + 1900; }
    NSArray<NSString *> *examples = @[
        @"Password|0|XXXXYYYYZZZZ9999||case=mixed,mixmask=true,pwsafe=true",
        [NSString stringWithFormat:@"Birth date|3|dd-MM-yyyy|%d..%d|", yr-65, yr-18],
        @"Sex|0||Male,Female|",
        @"Length cm|1||140..200|empty=5",
        @"Weight kg|2||50.0..100.0|empty=5",
        @"Postal code|0|9999XX||",
        [NSString stringWithFormat:@"Follow-up date|3|M/d/yyyy|%d-01..%d-05|", yr, yr],
        @"Glucose BL mmol/l|2||3,9..5,6|",
        @"Lab verified 75perc|0||Yes,Yes,Yes,No|",
        @"Remarks free text|0|||width=50"
    ];
    if (self.addExampleIdx >= (int)examples.count) self.addExampleIdx = 0;
    NSArray<NSString *> *a = [examples[self.addExampleIdx] componentsSeparatedByString:@"|"];
    self.addExampleIdx++;
    NSInteger idx = self.table.selectedRow >= 0 ? self.table.selectedRow + 1 : (NSInteger)self.columns.count;
    RVColumn *c = [RVColumn new];
    c.desc = [NSString stringWithFormat:@"%@ (%ld)", a[0], (long)(idx + 1)];
    c.dataType = a[1].intValue; c.mask = a[2]; c.range = a[3]; c.options = a[4];
    [self.columns insertObject:c atIndex:idx];
    [self.table reloadData];
    [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:idx] byExtendingSelection:NO];
}
- (void)delRow:(id)s {
    NSInteger row = self.table.selectedRow;
    if (row < 0 || row >= (NSInteger)self.columns.count) return;
    [self.columns removeObjectAtIndex:row];
    [self.table reloadData];
}
- (void)outputChanged:(id)s { [self updateConditionalControls]; }
- (void)stepperChanged:(id)s { self.amountField.integerValue = self.amountStepper.integerValue; }

- (void)ok:(id)sender {
    [self.window makeFirstResponder:nil]; // commit any in-progress edit
    // serialize columns -> settings
    for (int i = 0; i < 30; ++i) {
        std::string def;
        if (i < (int)self.columns.count) {
            RVColumn *c = self.columns[i];
            std::string desc = nsToStd(c.desc);
            std::string msk = trim(nsToStd(c.mask));
            std::string rng = trim(nsToStd(c.range));
            std::string opt = trim(nsToStd(c.options));
            if (!msk.empty()) msk = "(" + msk + ")";
            if (!rng.empty()) rng = " {" + rng + "}";
            if (!opt.empty()) opt = " [" + opt + "]";
            def = "\"" + desc + "\" " + typeNameForIdx(c.dataType) + msk + rng + opt;
        }
        g_settings.GenerateCol[i] = def;
    }
    g_settings.GenerateType = (int)self.outputPopup.indexOfSelectedItem;
    g_settings.GenerateAmount = self.amountField.intValue > 0 ? self.amountField.intValue : 1;
    g_settings.GenerateTablename = nsToStd(self.tablenameField.stringValue);
    g_settings.SQLtype = (int)self.sqlTypePopup.indexOfSelectedItem;
    g_settings.GenerateBatch = std::max(10, self.batchField.intValue);
    saveSettings();
    self.result = NSModalResponseOK;
    [NSApp stopModal];
}
- (void)cancel:(id)sender { self.result = NSModalResponseCancel; [NSApp stopModal]; }

- (NSModalResponse)runModal {
    self.result = NSModalResponseCancel;
    [self.window center];
    [NSApp runModalForWindow:self.window];
    [self.window orderOut:nil];
    return self.result;
}
@end

static void showGenerateWindow() {
    @autoreleasepool {
        static RVGenerateController *ctrl = nil;
        ctrl = [[RVGenerateController alloc] init]; // fresh each time (reloads from settings)
        if ([ctrl runModal] == NSModalResponseOK) {
            std::string out = generateOutput();
            emitToNewFile(out);
        }
    }
}

// ===========================================================================
// Settings window (property grid)
// ===========================================================================
@interface RVSettingRow : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *key;
@property(nonatomic, copy) NSString *type;   // section / bool / int / string
@property(nonatomic, copy) NSString *help;
@property(nonatomic, strong) NSMutableArray<RVSettingRow *> *children;
@end
@implementation RVSettingRow @end

@interface RVSettingsController : NSObject <NSOutlineViewDataSource, NSOutlineViewDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSOutlineView *outline;
@property(nonatomic, strong) NSArray<RVSettingRow *> *sections;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *values; // working copy
@property(nonatomic, strong) NSTextField *helpField;
@property(nonatomic, assign) NSModalResponse result;
@end

@implementation RVSettingsController

- (instancetype)init { if ((self = [super init])) { [self loadValues]; [self buildSections]; [self build]; } return self; }

- (void)loadValues {
    self.values = [NSMutableDictionary dictionary];
    self.values[@"LineFeed"] = g_settings.LineFeed ? @"True" : @"False";
    self.values[@"ToolbarRepeatLast"] = g_settings.ToolbarRepeatLast ? @"True" : @"False";
    self.values[@"MenuItem1"] = stdToNs(g_settings.MenuItem1);
    self.values[@"MenuItem2"] = stdToNs(g_settings.MenuItem2);
    self.values[@"MenuItem3"] = stdToNs(g_settings.MenuItem3);
    self.values[@"MenuItem4"] = stdToNs(g_settings.MenuItem4);
    self.values[@"MenuItem5"] = stdToNs(g_settings.MenuItem5);
    self.values[@"AutoSyntaxLimit"] = [NSString stringWithFormat:@"%d", g_settings.AutoSyntaxLimit];
    self.values[@"GenerateAmount"] = [NSString stringWithFormat:@"%d", g_settings.GenerateAmount];
    self.values[@"GenerateBatch"] = [NSString stringWithFormat:@"%d", g_settings.GenerateBatch];
    self.values[@"GenerateTablename"] = stdToNs(g_settings.GenerateTablename);
    self.values[@"GenerateType"] = [NSString stringWithFormat:@"%d", g_settings.GenerateType];
    self.values[@"SQLtype"] = [NSString stringWithFormat:@"%d", g_settings.SQLtype];
    for (int i = 0; i < 30; ++i) {
        NSString *k = [NSString stringWithFormat:@"GenerateCol%02d", i + 1];
        self.values[k] = stdToNs(g_settings.GenerateCol[i]);
    }
}

- (RVSettingRow *)row:(NSString *)name key:(NSString *)key type:(NSString *)t help:(NSString *)h {
    RVSettingRow *r = [RVSettingRow new]; r.name = name; r.key = key; r.type = t; r.help = h; return r;
}
- (RVSettingRow *)section:(NSString *)name children:(NSArray<RVSettingRow *> *)kids {
    RVSettingRow *s = [RVSettingRow new]; s.name = name; s.type = @"section"; s.children = [kids mutableCopy]; return s;
}

- (void)buildSections {
    NSMutableArray<RVSettingRow *> *menu = [NSMutableArray array];
    for (int i = 1; i <= 5; ++i)
        [menu addObject:[self row:[NSString stringWithFormat:@"MenuItem%d", i]
                              key:[NSString stringWithFormat:@"MenuItem%d", i] type:@"string"
                             help:@"Random value settings for this menu item. Close and restart Nextpad++ when changing menu items."]];
    NSMutableArray<RVSettingRow *> *cols = [NSMutableArray array];
    for (int i = 1; i <= 30; ++i)
        [cols addObject:[self row:[NSString stringWithFormat:@"GenerateCol%02d", i]
                              key:[NSString stringWithFormat:@"GenerateCol%02d", i] type:@"string"
                             help:[NSString stringWithFormat:@"Generate random values, definition column %d", i]]];
    self.sections = @[
        [self section:@"General" children:@[
            [self row:@"LineFeed" key:@"LineFeed" type:@"bool" help:@"Random value adds a line feed; set to false for no line feed."],
            [self row:@"ToolbarRepeatLast" key:@"ToolbarRepeatLast" type:@"bool" help:@"Toolbar icon repeats the last random value; set to false and the toolbar icon opens the Generate Values window. Restart Nextpad++ after changing."],
        ]],
        [self section:@"Menu items" children:menu],
        [self section:@"RandomGenerate" children:@[
            [self row:@"AutoSyntaxLimit" key:@"AutoSyntaxLimit" type:@"int" help:@"Automatically apply syntax highlighting to SQL/XML/JSON result only when smaller than this size (bytes)."],
            [self row:@"GenerateAmount" key:@"GenerateAmount" type:@"int" help:@"The amount of random value records to generate."],
            [self row:@"GenerateBatch" key:@"GenerateBatch" type:@"int" help:@"Generate SQL maximum records per insert batch; minimum batch size is 10."],
            [self row:@"GenerateTablename" key:@"GenerateTablename" type:@"string" help:@"Generate tablename or recordname, for SQL, XML and JSON."],
            [self row:@"GenerateType" key:@"GenerateType" type:@"int" help:@"The output type for the random values to generate (0=CSV,1=Tab,2=Semicolon,3=SQL,4=XML,5=JSON)."],
            [self row:@"SQLtype" key:@"SQLtype" type:@"int" help:@"Generate SQL for database type mySQL, MS-SQL or PostgreSQL (0, 1 or 2)."],
        ]],
        [self section:@"RandomGenerateCols" children:cols],
    ];
}

- (void)build {
    NSRect r = NSMakeRect(0, 0, 720, 560);
    _window = [[NSWindow alloc] initWithContentRect:r
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
        backing:NSBackingStoreBuffered defer:YES];
    _window.title = @"Settings - Random values plug-in";
    _window.minSize = NSMakeSize(560, 400);
    NSView *root = _window.contentView;

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(12, 96, 696, 452)];
    scroll.hasVerticalScroller = YES; scroll.borderType = NSLineBorder;
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _outline = [[NSOutlineView alloc] initWithFrame:scroll.bounds];
    _outline.dataSource = self; _outline.delegate = self;
    _outline.headerView = [[NSTableHeaderView alloc] init];
    _outline.rowSizeStyle = NSTableViewRowSizeStyleSmall;
    NSTableColumn *c1 = [[NSTableColumn alloc] initWithIdentifier:@"name"]; c1.title = @"Property"; c1.width = 280;
    NSTableColumn *c2 = [[NSTableColumn alloc] initWithIdentifier:@"value"]; c2.title = @"Value"; c2.width = 380;
    [_outline addTableColumn:c1]; [_outline addTableColumn:c2];
    _outline.outlineTableColumn = c1;
    scroll.documentView = _outline;
    [root addSubview:scroll];

    _helpField = [NSTextField wrappingLabelWithString:@""];
    _helpField.frame = NSMakeRect(12, 50, 696, 40);
    _helpField.textColor = [NSColor secondaryLabelColor];
    _helpField.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [root addSubview:_helpField];

    NSButton *ok = [NSButton buttonWithTitle:@"Ok" target:self action:@selector(ok:)];
    ok.frame = NSMakeRect(618, 12, 90, 30); ok.keyEquivalent = @"\r"; ok.autoresizingMask = NSViewMinXMargin; [root addSubview:ok];
    NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
    cancel.frame = NSMakeRect(520, 12, 90, 30); cancel.keyEquivalent = @"\e"; cancel.autoresizingMask = NSViewMinXMargin; [root addSubview:cancel];

    [_outline reloadData];
    for (RVSettingRow *s in _sections) [_outline expandItem:s];
}

// ---- outline data source ----
- (NSInteger)outlineView:(NSOutlineView *)ov numberOfChildrenOfItem:(id)item {
    if (!item) return self.sections.count;
    return ((RVSettingRow *)item).children.count;
}
- (id)outlineView:(NSOutlineView *)ov child:(NSInteger)idx ofItem:(id)item {
    if (!item) return self.sections[idx];
    return ((RVSettingRow *)item).children[idx];
}
- (BOOL)outlineView:(NSOutlineView *)ov isItemExpandable:(id)item { return ((RVSettingRow *)item).children.count > 0; }

- (NSView *)outlineView:(NSOutlineView *)ov viewForTableColumn:(NSTableColumn *)col item:(id)item {
    RVSettingRow *r = (RVSettingRow *)item;
    NSTableCellView *cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, col.width, 20)];
    if ([col.identifier isEqualToString:@"name"]) {
        NSTextField *tf = [NSTextField labelWithString:r.name ?: @""];
        if ([r.type isEqualToString:@"section"]) tf.font = [NSFont boldSystemFontOfSize:11];
        tf.frame = NSMakeRect(2, 2, col.width - 4, 16);
        tf.autoresizingMask = NSViewWidthSizable;
        [cell addSubview:tf]; cell.textField = tf;
        return cell;
    }
    if ([r.type isEqualToString:@"section"]) return cell;
    if ([r.type isEqualToString:@"bool"]) {
        NSButton *b = [NSButton checkboxWithTitle:@"" target:self action:@selector(boolChanged:)];
        b.state = [self.values[r.key] isEqualToString:@"True"] ? NSControlStateValueOn : NSControlStateValueOff;
        b.identifier = r.key; b.frame = NSMakeRect(2, 1, 18, 18);
        [cell addSubview:b];
        return cell;
    }
    NSTextField *tf = [[NSTextField alloc] initWithFrame:NSMakeRect(2, 1, col.width - 4, 18)];
    tf.stringValue = self.values[r.key] ?: @"";
    tf.identifier = r.key; tf.delegate = (id<NSTextFieldDelegate>)self;
    tf.bordered = NO; tf.drawsBackground = NO;
    tf.autoresizingMask = NSViewWidthSizable;
    [cell addSubview:tf]; cell.textField = tf;
    return cell;
}
- (void)boolChanged:(NSButton *)sender {
    self.values[sender.identifier] = (sender.state == NSControlStateValueOn) ? @"True" : @"False";
}
- (void)controlTextDidEndEditing:(NSNotification *)note {
    NSTextField *tf = note.object;
    if (tf.identifier) self.values[tf.identifier] = tf.stringValue;
}
- (void)outlineViewSelectionDidChange:(NSNotification *)note {
    NSInteger row = self.outline.selectedRow;
    if (row < 0) return;
    RVSettingRow *r = [self.outline itemAtRow:row];
    self.helpField.stringValue = (r.name && r.help) ? [NSString stringWithFormat:@"%@\n%@", r.name, r.help] : (r.help ?: @"");
}

- (void)ok:(id)sender {
    [self.window makeFirstResponder:nil];
    auto sv = ^(NSString *k, std::string &dst){ NSString *v = self.values[k]; if (v) dst = nsToStd(v); };
    auto bv = ^(NSString *k, bool &dst){ NSString *v = self.values[k]; if (v) dst = [v isEqualToString:@"True"]; };
    auto iv = ^(NSString *k, int &dst){ NSString *v = self.values[k]; if (v) dst = v.intValue; };
    bv(@"LineFeed", g_settings.LineFeed);
    bv(@"ToolbarRepeatLast", g_settings.ToolbarRepeatLast);
    sv(@"MenuItem1", g_settings.MenuItem1); sv(@"MenuItem2", g_settings.MenuItem2);
    sv(@"MenuItem3", g_settings.MenuItem3); sv(@"MenuItem4", g_settings.MenuItem4);
    sv(@"MenuItem5", g_settings.MenuItem5);
    iv(@"AutoSyntaxLimit", g_settings.AutoSyntaxLimit);
    iv(@"GenerateAmount", g_settings.GenerateAmount);
    iv(@"GenerateBatch", g_settings.GenerateBatch);
    if (g_settings.GenerateBatch < 10) g_settings.GenerateBatch = 10;
    sv(@"GenerateTablename", g_settings.GenerateTablename);
    iv(@"GenerateType", g_settings.GenerateType);
    iv(@"SQLtype", g_settings.SQLtype);
    for (int i = 0; i < 30; ++i) {
        NSString *k = [NSString stringWithFormat:@"GenerateCol%02d", i + 1];
        sv(k, g_settings.GenerateCol[i]);
    }
    saveSettings();
    rebuildMenuItems();
    self.result = NSModalResponseOK;
    [NSApp stopModal];
}
- (void)cancel:(id)sender { self.result = NSModalResponseCancel; [NSApp stopModal]; }

- (void)runModal {
    self.result = NSModalResponseCancel;
    [self.window center];
    [NSApp runModalForWindow:self.window];
    [self.window orderOut:nil];
}
@end

static void showSettingsWindow() {
    @autoreleasepool {
        static RVSettingsController *ctrl = nil;
        ctrl = [[RVSettingsController alloc] init];
        [ctrl runModal];
    }
}

// ===========================================================================
// Toolbar icon
// ===========================================================================
static void handleToolbarModification() {
    int idx = g_settings.ToolbarRepeatLast ? MI_Repeat : MI_Generate;
    npp(NPPM_ADDTOOLBARICON_FORDARKMODE, (uintptr_t)funcItem[idx]._cmdID, (intptr_t)"dice.png");
}

// ===========================================================================
// Build the 5 menu RandomValue objects + menu labels
// ===========================================================================
static void rebuildMenuItems() {
    const std::string *specs[5] = {
        &g_settings.MenuItem1, &g_settings.MenuItem2, &g_settings.MenuItem3,
        &g_settings.MenuItem4, &g_settings.MenuItem5
    };
    for (int i = 0; i < 5; ++i) g_menuRnd[i] = RandomValue(*specs[i]);
}

// ===========================================================================
// Plugin exports
// ===========================================================================
static void setItem(int idx, const std::string &name, PFUNCPLUGINCMD fn) {
    strncpy(funcItem[idx]._itemName, name.c_str(), NPP_MENU_ITEM_SIZE - 1);
    funcItem[idx]._itemName[NPP_MENU_ITEM_SIZE - 1] = 0;
    funcItem[idx]._pFunc = fn;
}

extern "C" NPP_EXPORT void setInfo(NppData data) {
    nppData = data;
    memset(funcItem, 0, sizeof(funcItem));
    loadSettings();
    rebuildMenuItems();

    setItem(MI_Item1, g_menuRnd[0].Description, cmdItem1);
    setItem(MI_Item2, g_menuRnd[1].Description, cmdItem2);
    setItem(MI_Item3, g_menuRnd[2].Description, cmdItem3);
    setItem(MI_Item4, g_menuRnd[3].Description, cmdItem4);
    setItem(MI_Item5, g_menuRnd[4].Description, cmdItem5);
    setItem(MI_Sep1, "", nullptr);
    setItem(MI_Repeat, "Repeat random value", cmdRepeat);
    setItem(MI_Generate, "Generate random values", cmdGenerate);
    setItem(MI_Sep2, "", nullptr);
    setItem(MI_Settings, "Settings", cmdSettings);
    setItem(MI_About, "About", cmdAbout);
}

extern "C" NPP_EXPORT const char *getName() { return PLUGIN_NAME; }

extern "C" NPP_EXPORT FuncItem *getFuncsArray(int *nbF) { *nbF = NB_FUNC; return funcItem; }

extern "C" NPP_EXPORT void beNotified(SCNotification *n) {
    if (!n) return;
    switch (n->nmhdr.code) {
        case NPPN_TBMODIFICATION: handleToolbarModification(); break;
        case NPPN_SHUTDOWN: saveSettings(); break;
        default: break;
    }
}

extern "C" NPP_EXPORT intptr_t messageProc(uint32_t, uintptr_t, intptr_t) { return 1; }
