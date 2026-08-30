/* lk_json — see lk_json.h. */
#include "lk_json.h"

#include <algorithm>
#include <cstdlib>

namespace lkw::json
{
    namespace
    {
        std::string const kEmpty;

        bool IsHex(char c)
        {
            return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
        }

        /* One code point as UTF-8. The shell's text is UTF-8 end to end, so an
         * escape lands in the same encoding the unescaped bytes did. */
        void AppendUtf8(std::string &out, uint32_t code)
        {
            if (code < 0x80)
            {
                out += (char)code;
            }
            else if (code < 0x800)
            {
                out += (char)(0xC0 | (code >> 6));
                out += (char)(0x80 | (code & 0x3F));
            }
            else if (code < 0x10000)
            {
                out += (char)(0xE0 | (code >> 12));
                out += (char)(0x80 | ((code >> 6) & 0x3F));
                out += (char)(0x80 | (code & 0x3F));
            }
            else
            {
                out += (char)(0xF0 | (code >> 18));
                out += (char)(0x80 | ((code >> 12) & 0x3F));
                out += (char)(0x80 | ((code >> 6) & 0x3F));
                out += (char)(0x80 | (code & 0x3F));
            }
        }
    }

    /* ---- the reader ------------------------------------------------------ */

    class Reader
    {
    public:
        Reader(char const *begin, char const *end) : p_(begin), end_(end) {}

        bool ReadValue(Value &out, int depth);
        void SkipSpace();
        bool AtEnd() const { return p_ >= end_; }
        char Peek() const { return p_ < end_ ? *p_ : '\0'; }

    private:
        bool ReadString(std::string &out);
        bool ReadEscapeUnicode(std::string &out);
        bool ReadNumber(Value &out);
        bool ReadLiteral(char const *word, size_t len);

        char const *p_;
        char const *end_;
    };

    void Reader::SkipSpace()
    {
        while (p_ < end_ && (*p_ == ' ' || *p_ == '\t' || *p_ == '\n' || *p_ == '\r'))
            p_++;
    }

    /* One \uXXXX escape. A high surrogate takes its low half with it, because a
     * cell name outside the BMP arrives as a pair; a lone surrogate becomes
     * U+FFFD rather than invalid UTF-8 in a label. */
    bool Reader::ReadEscapeUnicode(std::string &out)
    {
        if (end_ - p_ < 4)
            return false;
        char hex[5] = { 0 };
        for (int i = 0; i < 4; i++)
        {
            if (!IsHex(p_[i]))
                return false;
            hex[i] = p_[i];
        }
        p_ += 4;
        uint32_t code = (uint32_t)std::strtoul(hex, nullptr, 16);

        if (code >= 0xD800 && code <= 0xDBFF && end_ - p_ >= 6 && p_[0] == '\\' && p_[1] == 'u')
        {
            char low_hex[5] = { 0 };
            bool all_hex = true;
            for (int i = 0; i < 4; i++)
            {
                if (!IsHex(p_[2 + i]))
                {
                    all_hex = false;
                    break;
                }
                low_hex[i] = p_[2 + i];
            }
            if (all_hex)
            {
                uint32_t low = (uint32_t)std::strtoul(low_hex, nullptr, 16);
                if (low >= 0xDC00 && low <= 0xDFFF)
                {
                    p_ += 6;
                    code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
                }
            }
        }

        if (code >= 0xD800 && code <= 0xDFFF)
            code = 0xFFFD;

        AppendUtf8(out, code);
        return true;
    }

    /* The text between the quotes, unescaped. p_ is on the opening quote. */
    bool Reader::ReadString(std::string &out)
    {
        if (Peek() != '"')
            return false;
        p_++;

        while (true)
        {
            if (p_ >= end_)
                return false;
            if (*p_ == '"')
            {
                p_++;
                return true;
            }
            if (*p_ != '\\')
            {
                out += *p_++;
                continue;
            }

            p_++;
            if (p_ >= end_)
                return false;
            switch (*p_)
            {
            case '"':  out += '"';  p_++; break;
            case '\\': out += '\\'; p_++; break;
            case '/':  out += '/';  p_++; break;
            case 'b':  out += '\b'; p_++; break;
            case 'f':  out += '\f'; p_++; break;
            case 'n':  out += '\n'; p_++; break;
            case 'r':  out += '\r'; p_++; break;
            case 't':  out += '\t'; p_++; break;
            case 'u':
                p_++;
                if (!ReadEscapeUnicode(out))
                    return false;
                break;
            default:
                return false;
            }
        }
    }

    bool Reader::ReadNumber(Value &out)
    {
        /* strtod on a NUL-terminated copy: the span may not be terminated, and
         * it would otherwise also take "inf", "nan" and a leading "0x", none of
         * which are JSON numbers. */
        char const *start = p_;
        if (Peek() == '-')
            p_++;
        bool any_digit = false;
        while (p_ < end_ && *p_ >= '0' && *p_ <= '9')
        {
            p_++;
            any_digit = true;
        }
        if (!any_digit)
            return false;
        if (Peek() == '.')
        {
            p_++;
            any_digit = false;
            while (p_ < end_ && *p_ >= '0' && *p_ <= '9')
            {
                p_++;
                any_digit = true;
            }
            if (!any_digit)
                return false;
        }
        if (Peek() == 'e' || Peek() == 'E')
        {
            p_++;
            if (Peek() == '+' || Peek() == '-')
                p_++;
            any_digit = false;
            while (p_ < end_ && *p_ >= '0' && *p_ <= '9')
            {
                p_++;
                any_digit = true;
            }
            if (!any_digit)
                return false;
        }

        out.kind_ = Kind::Number;
        out.text_.assign(start, (size_t)(p_ - start));
        out.number_ = std::strtod(out.text_.c_str(), nullptr);
        return true;
    }

    bool Reader::ReadLiteral(char const *word, size_t len)
    {
        if ((size_t)(end_ - p_) < len)
            return false;
        for (size_t i = 0; i < len; i++)
            if (p_[i] != word[i])
                return false;
        p_ += len;
        return true;
    }

    bool Reader::ReadValue(Value &out, int depth)
    {
        if (depth > kMaxDepth)
            return false;
        SkipSpace();
        if (p_ >= end_)
            return false;

        switch (*p_)
        {
        case '{':
        {
            out.kind_ = Kind::Object;
            p_++;
            SkipSpace();
            if (Peek() == '}')
            {
                p_++;
                return true;
            }
            while (true)
            {
                std::string key;
                if (!ReadString(key))
                    return false;
                SkipSpace();
                if (Peek() != ':')
                    return false;
                p_++;
                Value value;
                if (!ReadValue(value, depth + 1))
                    return false;
                out.keys_.push_back(std::move(key));
                out.items_.push_back(std::move(value));
                SkipSpace();
                if (Peek() == ',')
                {
                    p_++;
                    SkipSpace();
                    continue;
                }
                if (Peek() == '}')
                {
                    p_++;
                    return true;
                }
                return false;
            }
        }
        case '[':
        {
            out.kind_ = Kind::Array;
            p_++;
            SkipSpace();
            if (Peek() == ']')
            {
                p_++;
                return true;
            }
            while (true)
            {
                Value item;
                if (!ReadValue(item, depth + 1))
                    return false;
                out.items_.push_back(std::move(item));
                SkipSpace();
                if (Peek() == ',')
                {
                    p_++;
                    continue;
                }
                if (Peek() == ']')
                {
                    p_++;
                    return true;
                }
                return false;
            }
        }
        case '"':
            out.kind_ = Kind::String;
            return ReadString(out.text_);
        case 't':
            if (!ReadLiteral("true", 4))
                return false;
            out.kind_ = Kind::Bool;
            out.boolean_ = true;
            out.text_ = "true";
            return true;
        case 'f':
            if (!ReadLiteral("false", 5))
                return false;
            out.kind_ = Kind::Bool;
            out.boolean_ = false;
            out.text_ = "false";
            return true;
        case 'n':
            if (!ReadLiteral("null", 4))
                return false;
            out.kind_ = Kind::Null;
            return true;
        default:
            return ReadNumber(out);
        }
    }

    /* ---- the tree --------------------------------------------------------- */

    Value const &Value::Nothing()
    {
        static Value const nothing;
        return nothing;
    }

    Value const &Value::Member(std::string_view name) const
    {
        if (kind_ != Kind::Object)
            return Nothing();
        for (size_t i = 0; i < keys_.size(); i++)
            if (keys_[i] == name)
                return items_[i];
        return Nothing();
    }

    std::vector<std::string> Value::MemberNames() const
    {
        std::vector<std::string> names;
        if (kind_ != Kind::Object)
            return names;
        names = keys_;
        std::sort(names.begin(), names.end());
        return names;
    }

    Value const &Value::At(size_t index) const
    {
        if (kind_ != Kind::Array || index >= items_.size())
            return Nothing();
        return items_[index];
    }

    std::vector<Value> const &Value::Items() const
    {
        static std::vector<Value> const none;
        return kind_ == Kind::Array ? items_ : none;
    }

    std::string const &Value::String() const
    {
        return kind_ == Kind::String ? text_ : kEmpty;
    }

    std::string Value::MemberString(std::string_view name, std::string const &fallback) const
    {
        Value const &v = Member(name);
        if (v.kind() != Kind::String || v.text_.empty())
            return fallback;
        return v.text_;
    }

    double Value::MemberNumber(std::string_view name, double fallback) const
    {
        return Member(name).Number(fallback);
    }

    bool Value::MemberBool(std::string_view name, bool fallback) const
    {
        return Member(name).Bool(fallback);
    }

    /* ---- the entry point -------------------------------------------------- */

    std::optional<Value> Parse(std::string_view text)
    {
        Reader reader(text.data(), text.data() + text.size());
        Value root;
        if (!reader.ReadValue(root, 0))
            return std::nullopt;
        /* Trailing junk is a failure: a half-parsed report is worse than none. */
        reader.SkipSpace();
        if (!reader.AtEnd())
            return std::nullopt;
        return root;
    }
}
