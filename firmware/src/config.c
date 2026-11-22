/*
 * TurboACE: the settings file /turboace.cfg (register-map.md decision 26).
 *
 *   # comment
 *   keyboard = pt          us (default) or pt
 *   keymode  = positional  symbolic (default) or positional
 *
 * Names and values are not case-sensitive; spaces around "=" are optional;
 * anything not understood is ignored, so an old file never stops the machine.
 */
#include "config.h"

static int lower(int c) { return c >= 'A' && c <= 'Z' ? c + 32 : c; }

static int word_is(const char *p, unsigned n, const char *w)
{
    unsigned i = 0;
    for (; i < n && w[i]; i++) if (lower(p[i]) != w[i]) return 0;
    return i == n && !w[i];
}

int config_parse(const char *text, unsigned len, struct tconfig *cfg)
{
    int understood = 0;
    cfg->layout = KBD_US;
    cfg->mode = KBD_SYMBOLIC;
    unsigned i = 0;
    while (i < len) {
        unsigned end = i;
        while (end < len && text[end] != '\n' && text[end] != '\r') end++;
        /* name */
        unsigned p = i;
        while (p < end && (text[p] == ' ' || text[p] == '\t')) p++;
        unsigned n0 = p;
        while (p < end && text[p] != '=' && text[p] != ' ' && text[p] != '\t' && text[p] != '#') p++;
        unsigned n1 = p;
        while (p < end && (text[p] == ' ' || text[p] == '\t')) p++;
        if (p < end && text[p] == '=' && n1 > n0) {
            p++;
            while (p < end && (text[p] == ' ' || text[p] == '\t')) p++;
            unsigned v0 = p;
            while (p < end && text[p] != ' ' && text[p] != '\t' && text[p] != '#') p++;
            unsigned v1 = p;
            const char *name = text + n0, *val = text + v0;
            unsigned nl = n1 - n0, vl = v1 - v0;
            if (word_is(name, nl, "keyboard")) {
                if (word_is(val, vl, "us")) { cfg->layout = KBD_US; understood++; }
                else if (word_is(val, vl, "pt")) { cfg->layout = KBD_PT; understood++; }
            } else if (word_is(name, nl, "keymode")) {
                if (word_is(val, vl, "symbolic")) { cfg->mode = KBD_SYMBOLIC; understood++; }
                else if (word_is(val, vl, "positional")) { cfg->mode = KBD_POSITIONAL; understood++; }
            }
        }
        i = end;
        while (i < len && (text[i] == '\n' || text[i] == '\r')) i++;
    }
    return understood;
}
