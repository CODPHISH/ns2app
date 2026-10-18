// String lookup for the UI text we added ourselves (English version; table = dm/i18n/ui_text.tsv, generator dm/ios/tools/dm_i18n.py)
#pragma once
#include <stdatomic.h>
#include <stdint.h>
extern _Atomic int g_dm_lang;                         // the original game's current language index (0 enUS ... 8 zhCN), written by the SetLanguage observation gate (diag.c); -1 = the game has not set it yet
int dm_lang_index(void);                              // current language index of the original game (set by the game > settings file > system language on first install)
int dm_lang_zh(void);                                 // 1 = our text uses Chinese (zhCN, zhTW); all other languages use English
int dm_lang_from_tag(const char *tag);                // language tag (en-US / zh-Hant-TW / es-419 ...) → the original game's language index: Chinese / Chinese varieties = 8 zhCN, everything else = 0 enUS
int dm_sys_lang(void);                                // system language → the original game's language index (DM_LANG > iOS preferred language > English)
const char *dm_str(uint8_t *main_base, const char *key);   // text drawn inside the game: the original string lookup (the table is appended to the original ui.json and switches language together with the original game)
const char *dm_ui(const char *key);                   // text drawn outside the game (UIKit / asset download page / bottom-bar glyphs): compile-time table, picked by dm_lang_zh()
