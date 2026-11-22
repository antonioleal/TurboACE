/*
 * TurboACE SD soft CPU: the $E5/$E7 protocol (register-map.md section 2.6),
 * on top of FatFs.
 *
 * sdp_command() runs a command when the Z80 writes one (EV_CMD);
 * sdp_xfer() moves the next data-phase chunk (EV_XFER). Both end with
 * hal_ready(), which lets the Z80 go on.
 *
 * The virtual tape player behaves like the Jupiter-IIb emulator's
 * (src/tape_sd.cpp), so programs and tape files act the same on both:
 *   - .tap: blocks of a 2-byte length (bytes + checksum), the bytes, an XOR
 *     checksum of the bytes. No flag byte: a block is a header when it is
 *     26 long and does not follow a header.
 *   - .tzx: the same blocks in TZX data blocks, with the flag byte first.
 *   - LOAD's header search goes once round the tape, then error 10. A LOAD
 *     without a name (search 2) starts from the tape's beginning.
 *   - SAVE with no tape in the player writes name.tap, the name from the
 *     header as the emulator makes it; with a tape in, it appends to it.
 *
 * Licence: the TZX block walker and the LOAD search follow Jupiter-IIb's
 * src/tape_sd.cpp (GPL v2 or later, derived from xAce): treat this file as GPL
 * v2+ unless those parts are cleared or rewritten.
 */
#include <string.h>
#include "ff.h"
#include "hal.h"
#include "sdproto.h"

/* ---- Commands and error codes (register-map.md 2.6) --------------------- */
enum {
    C_MOUNT = 0x01, C_DIRFIRST = 0x02, C_DIRNEXT = 0x03, C_CHDIR = 0x04, C_DELETE = 0x05,
    C_FREE = 0x06,
    C_OPENR = 0x10, C_OPENW = 0x11, C_READ = 0x12, C_WRITE = 0x13, C_CLOSE = 0x14,
    C_TINSERT = 0x20, C_TEJECT = 0x21, C_TREAD = 0x22, C_TWRITE = 0x23
};
enum {
    E_OK = 0, E_NOCARD = 1, E_NOTFOUND = 2, E_FULL = 3, E_READONLY = 4, E_IO = 5,
    E_BADNAME = 6, E_NOTOPEN = 7, E_TOOLARGE = 8, E_BADBLOCK = 9, E_ENDTAPE = 10
};

#define NAME_MAX     63         /* longest name the Z80 sends */
#define CHUNK        512        /* data-phase chunk */
#define XFER_MAX     8192       /* most bytes per READ / WRITE */
#define HEADER_SIZE  25         /* Ace tape header block */
#define TAPE_NAME    10         /* name characters in the header */
#define HOME         "/programs"

static const uint8_t tzx_signature[10] = { 'Z', 'X', 'T', 'a', 'p', 'e', '!', 0x1A, 1, 20 };
#define TZX_PAUSE_MS 1000

/* ---- State -------------------------------------------------------------- */
FATFS   sdp_fs;
static int     mounted;

static FIL     file;            /* OPENR / OPENW */
static int     file_mode;       /* 0 none, 1 read, 2 write */

static DIR     dir;
static FILINFO fno;
static int     dir_pass;        /* 0 folders, 1 files, 2 done */
static char    dir_pattern[NAME_MAX + 1];

static char    tape_path[NAME_MAX + 1 + 8];   /* the tape in the player ("" = none) */
static int     tape_tzx;
static FSIZE_t tape_pos;        /* next block */
static int     after_header;    /* .tap: the last block read was a header */
static int     searching, search_wrapped;
static FSIZE_t search_start;

static FIL     save;            /* SAVE: header written, data block to follow */
static int     save_open, save_tzx;

/* the data phase in progress */
static enum { P_NONE, P_READ, P_WRITE, P_TREAD, P_TWRITE } phase;
static uint32_t phase_left;     /* bytes still to move after the current chunk */
static unsigned chunk_len;      /* bytes in the chunk the Z80 is moving now */
static FIL      tfile;          /* TREAD / TWRITE: the tape or save file */
static uint8_t  check;          /* running XOR checksum */
static int      tw_flag;
static unsigned tw_len;
static uint8_t  header[HEADER_SIZE];
static uint8_t  buf[CHUNK];

/* ---- Small helpers ------------------------------------------------------ */
static unsigned flags(void)
{
    return (mounted ? ST_CARD : 0) | (tape_path[0] ? ST_TAPE : 0);
}

static void done(int err)
{
    if (err) {
        hal_res_clear();
        hal_res_push(err);
        hal_xfer(0);
        phase = P_NONE;
    }
    hal_ready(flags() | (err ? ST_ERROR : 0));
}

static int fr_error(FRESULT fr)
{
    switch (fr) {
    case FR_OK:                 return E_OK;
    case FR_NO_FILE:
    case FR_NO_PATH:            return E_NOTFOUND;
    case FR_INVALID_NAME:
    case FR_INVALID_PARAMETER:  return E_BADNAME;
    case FR_DENIED:
    case FR_EXIST:
    case FR_WRITE_PROTECTED:    return E_READONLY;
    case FR_INVALID_OBJECT:     return E_NOTOPEN;
    case FR_NOT_READY:
    case FR_NO_FILESYSTEM:
    case FR_INVALID_DRIVE:
    case FR_NOT_ENABLED:
        mounted = 0;            /* a new card, or none: mount again next time */
        return E_NOCARD;
    default:
        mounted = 0;
        return E_IO;
    }
}

static int arg_name(char *name)
{
    int len = hal_arg_pop();
    if (len <= 0 || len > NAME_MAX) {
        return 0;
    }
    for (int i = 0; i < len; i++) {
        int c = hal_arg_pop();
        if (c <= 0) {
            return 0;
        }
        name[i] = (char) c;
    }
    name[len] = '\0';
    return 1;
}

static int arg_u16(void)
{
    int lo = hal_arg_pop(), hi = hal_arg_pop();
    return lo < 0 || hi < 0 ? -1 : lo | hi << 8;
}

static void push_u32(uint32_t v)
{
    for (int i = 0; i < 4; i++) {
        hal_res_push((v >> (8 * i)) & 0xFF);
    }
}

static int has_ext(const char *name, const char *ext)
{
    size_t n = strlen(name), e = strlen(ext);
    if (n < e) {
        return 0;
    }
    for (size_t i = 0; i < e; i++) {
        char a = name[n - e + i], b = ext[i];
        if (a >= 'a' && a <= 'z') a -= 32;
        if (b >= 'a' && b <= 'z') b -= 32;
        if (a != b) return 0;
    }
    return 1;
}

static int ensure_mounted(void)
{
    if (mounted) {
        return E_OK;
    }
    if (f_mount(&sdp_fs, "", 1) != FR_OK) {
        return E_NOCARD;
    }
    mounted = 1;
    FRESULT fr = f_mkdir(HOME);
    if (fr != FR_OK && fr != FR_EXIST) {
        return fr_error(fr);
    }
    return fr_error(f_chdir(HOME));
}

static void close_file(void)
{
    if (file_mode) {
        f_close(&file);
        file_mode = 0;
    }
}

static void end_phase(void)
{
    if (phase == P_TREAD || phase == P_TWRITE) {
        f_close(&tfile);
    }
    phase = P_NONE;
}

/* ---- Directory ---------------------------------------------------------- */
/* the next entry for the current pass (folders, then files) into fno */
static int dir_entry(void)
{
    for (;;) {
        if (dir_pass > 1) {
            return 0;
        }
        FRESULT fr = fno.fname[0] == 0 && !dir.obj.fs
                   ? f_findfirst(&dir, &fno, "", dir_pattern)
                   : f_findnext(&dir, &fno);
        if (fr != FR_OK) {
            return -fr_error(fr);
        }
        if (fno.fname[0] == 0) {        /* this pass is over */
            f_closedir(&dir);
            memset(&dir, 0, sizeof dir);
            dir_pass++;
            continue;
        }
        if (fno.fattrib & (AM_HID | AM_SYS)) {
            continue;
        }
        if (((fno.fattrib & AM_DIR) != 0) == (dir_pass == 0)) {
            return 1;
        }
    }
}

static void push_entry(int found)
{
    if (!found) {
        hal_res_push(0xFF);
        return;
    }
    size_t n = strlen(fno.fname);
    if (n > NAME_MAX) {
        n = NAME_MAX;
    }
    FSIZE_t size = fno.fsize > 0xFFFFFFFFu ? 0xFFFFFFFFu : fno.fsize;
    hal_res_push(fno.fattrib & AM_DIR ? 1 : 0);
    push_u32((uint32_t) size);
    hal_res_push((int) n);
    for (size_t i = 0; i < n; i++) {
        hal_res_push((uint8_t) fno.fname[i]);
    }
}

/* ---- Tape: reading blocks ----------------------------------------------- */
static int read_exact(FIL *f, void *p, UINT n)
{
    UINT got;
    return f_read(f, p, n, &got) == FR_OK && got == n;
}

static uint32_t le(const uint8_t *p, int n)
{
    uint32_t v = 0;
    while (n--) {
        v = v << 8 | p[n];
    }
    return v;
}

/* TZX: on to the next data block; the file is left at its flag byte, *total
 * = flag + bytes + checksum. Data blocks: 10h, 11h, 14h, and 19h with one bit
 * per symbol; others are skipped. */
static int next_tzx_block(FIL *f, uint32_t *total)
{
    if (f_tell(f) == 0) {
        uint8_t sig[10];
        if (!read_exact(f, sig, 10) || memcmp(sig, tzx_signature, 8) != 0) {
            return 0;
        }
    }
    for (;;) {
        uint8_t id, fld[18];
        uint32_t data = 0;
        FSIZE_t skip = 0;
        if (!read_exact(f, &id, 1)) {
            return 0;
        }
        switch (id) {
        case 0x10: if (!read_exact(f, fld, 4)) return 0; data = le(fld + 2, 2); break;
        case 0x11: if (!read_exact(f, fld, 18)) return 0; data = le(fld + 15, 3); break;
        case 0x14: if (!read_exact(f, fld, 10)) return 0; data = le(fld + 7, 3); break;
        case 0x19: {
            if (!read_exact(f, fld, 18)) return 0;
            FSIZE_t end = f_tell(f) - 14 + le(fld, 4);
            uint32_t ps = le(fld + 6, 4), pp = fld[10], pa = fld[11] ? fld[11] : 256;
            uint32_t ds = le(fld + 12, 4), dp = fld[16], da = fld[17] ? fld[17] : 256;
            FSIZE_t tables = 0;
            if (ps) tables += pa * (1 + 2 * pp) + ps * 3;
            if (ds) tables += da * (1 + 2 * dp);
            if (da == 2 && ds >= 16 && ds % 8 == 0) {
                if (f_lseek(f, f_tell(f) + tables) != FR_OK) return 0;
                data = ds / 8;
            } else {
                skip = end - f_tell(f);
            }
            break;
        }
        case 0x12: skip = 4; break;
        case 0x13: if (!read_exact(f, fld, 1)) return 0; skip = fld[0] * 2; break;
        case 0x15: if (!read_exact(f, fld, 8)) return 0; skip = le(fld + 5, 3); break;
        case 0x20: case 0x23: case 0x24: skip = 2; break;
        case 0x21: case 0x30: if (!read_exact(f, fld, 1)) return 0; skip = fld[0]; break;
        case 0x22: case 0x25: case 0x27: skip = 0; break;
        case 0x26: if (!read_exact(f, fld, 2)) return 0; skip = le(fld, 2) * 2; break;
        case 0x28: case 0x32: if (!read_exact(f, fld, 2)) return 0; skip = le(fld, 2); break;
        case 0x31: if (!read_exact(f, fld, 2)) return 0; skip = fld[1]; break;
        case 0x33: if (!read_exact(f, fld, 1)) return 0; skip = fld[0] * 3; break;
        case 0x35: if (!read_exact(f, fld, 14)) return 0; skip = le(fld + 10, 4); break;
        case 0x5A: skip = 9; break;
        default:   if (!read_exact(f, fld, 4)) return 0; skip = le(fld, 4); break;
        }
        if (data >= 2) {
            *total = data;
            return 1;
        }
        if (f_lseek(f, f_tell(f) + skip + data) != FR_OK || f_tell(f) > f_size(f)) {
            return 0;
        }
    }
}

/* Open the tape at tape_pos and read the next block's frame: tfile is left
 * at its first byte; *flag, *bytes (without the checksum); tape_pos moves past
 * the block. 0 at the end of the tape. */
static int open_block(uint8_t *flag, uint32_t *bytes)
{
    if (f_open(&tfile, tape_path, FA_READ) != FR_OK) {
        return 0;
    }
    if (f_lseek(&tfile, tape_pos) != FR_OK || f_tell(&tfile) != tape_pos) {
        f_close(&tfile);
        return 0;
    }
    uint32_t total;
    int ok;
    if (tape_tzx) {
        ok = next_tzx_block(&tfile, &total) && read_exact(&tfile, flag, 1);
        total -= 1;                     /* bytes + checksum */
    } else {
        uint8_t len[2];
        ok = read_exact(&tfile, len, 2);
        total = le(len, 2);
        *flag = !after_header && total == HEADER_SIZE + 1 ? 0x00 : 0xFF;
    }
    if (!ok || total < 1 || f_tell(&tfile) + total > f_size(&tfile) + 0) {
        f_close(&tfile);
        return 0;
    }
    *bytes = total - 1;
    tape_pos = f_tell(&tfile) + total;
    after_header = *flag == 0x00;
    return 1;
}

/* the next chunk of a READ or TREAD data phase from fil into the RES FIFO */
static int push_chunk(FIL *fil, unsigned n)
{
    UINT got;
    if (f_read(fil, buf, n, &got) != FR_OK || got != n) {
        return 0;
    }
    for (unsigned i = 0; i < n; i++) {
        hal_res_push(buf[i]);
        check ^= buf[i];
    }
    chunk_len = n;
    hal_xfer(n);
    return 1;
}

static void tread(void)
{
    int flag = hal_arg_pop(), len = arg_u16(), search = hal_arg_pop();
    if (flag < 0 || len < 0 || search < 0) {
        done(E_BADNAME);
        return;
    }
    if (!tape_path[0]) {                 /* no tape: LOAD fails, a reader just gets no block */
        done(search ? E_ENDTAPE : E_BADBLOCK);
        return;
    }
    if (!search) {
        searching = 0;
    } else if (!searching) {
        searching = 1;
        if (search == 2) {               /* LOAD without a name: from the tape's start */
            tape_pos = 0;
            after_header = 0;
        }
        search_start = tape_pos;
        search_wrapped = search_start == 0;
    }

    uint8_t bflag;
    uint32_t bytes;
    for (;;) {
        FSIZE_t at = tape_pos;
        int ok = open_block(&bflag, &bytes);
        if (ok && search && search_wrapped && search_start > 0 && at >= search_start) {
            f_close(&tfile);
            tape_pos = at;               /* back where the search began */
            ok = 0;
        } else if (!ok && search && !search_wrapped) {
            search_wrapped = 1;          /* on from the start of the tape */
            tape_pos = 0;
            after_header = 0;
            continue;
        }
        if (ok) {
            break;
        }
        if (search) {
            searching = 0;
            done(E_ENDTAPE);
        } else {
            done(E_BADBLOCK);            /* the end of the tape */
        }
        return;
    }

    if (bflag != flag || bytes != (uint32_t) len) {
        f_close(&tfile);
        done(E_BADBLOCK);                /* the other kind of block, or the wrong size */
        return;
    }
    check = 0;
    phase = P_TREAD;
    phase_left = bytes;
    if (bytes == 0) {
        sdp_xfer();                      /* only the checksum to check */
        return;
    }
    unsigned n = bytes > CHUNK ? CHUNK : bytes;
    phase_left -= n;
    if (!push_chunk(&tfile, n)) {
        end_phase();
        done(E_BADBLOCK);
        return;
    }
    hal_ready(flags());
}

/* ---- Tape: writing blocks ----------------------------------------------- */
/* name.tap from an Ace header's name, as the Jupiter-IIb emulator makes it */
static void header_path(char *path)
{
    int n = 0, len = 0;
    for (int i = 0; i < TAPE_NAME; i++) {
        uint8_t c = header[1 + i] & 0x7F;
        int keep = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
                   || c == '-' || c == '_';
        path[n++] = keep ? (char) c : c == ' ' ? ' ' : '_';
        if (path[n - 1] != ' ') {
            len = n;
        }
    }
    if (len == 0) {
        strcpy(path, "noname");
        len = 6;
    }
    strcpy(path + len, ".tap");
}

static int write_frame(FIL *f, int tzx, int fl, unsigned len)
{
    UINT w;
    if (tzx) {
        if (f_size(f) == 0 && (f_write(f, tzx_signature, 10, &w) != FR_OK || w != 10)) {
            return 0;
        }
        unsigned n = len + 2;            /* flag, bytes, checksum */
        uint8_t b[6] = { 0x10, TZX_PAUSE_MS & 0xFF, TZX_PAUSE_MS >> 8, n & 0xFF, n >> 8,
                         (uint8_t) fl };
        return f_write(f, b, 6, &w) == FR_OK && w == 6;
    }
    uint8_t b[2] = { (len + 1) & 0xFF, (len + 1) >> 8 };
    return f_write(f, b, 2, &w) == FR_OK && w == 2;
}

static void twrite(void)
{
    int flag = hal_arg_pop(), len = arg_u16();
    if (flag < 0 || len < 0) {
        done(E_BADNAME);
        return;
    }
    tw_flag = flag;
    tw_len = (unsigned) len;
    check = 0;
    if (flag == 0x00) {                  /* a header: kept until it is complete */
        if (save_open) {
            f_close(&save);
            save_open = 0;
        }
        if (len != HEADER_SIZE) {
            done(E_BADBLOCK);
            return;
        }
    } else if (!save_open) {
        done(E_NOTOPEN);                 /* data with no header before it */
        return;
    } else if (!write_frame(&save, save_tzx, flag, tw_len)) {
        done(E_FULL);
        return;
    }
    phase = P_TWRITE;
    phase_left = tw_len;
    if (tw_len == 0) {
        sdp_xfer();
        return;
    }
    chunk_len = tw_len > CHUNK ? CHUNK : tw_len;
    phase_left -= chunk_len;
    hal_xfer(chunk_len);
    hal_ready(flags());
}

/* the end of a TWRITE: the block is complete */
static int twrite_end(void)
{
    UINT w;
    if (tw_flag == 0x00) {               /* the header: start the file */
        char path[NAME_MAX + 1 + 8];
        int append = tape_path[0] != 0;
        if (append) {
            strcpy(path, tape_path);
        } else {
            header_path(path);
        }
        if (f_open(&save, path, FA_WRITE | (append ? FA_OPEN_APPEND : FA_CREATE_ALWAYS)) != FR_OK) {
            return E_READONLY;
        }
        save_open = 1;
        save_tzx = has_ext(path, ".tzx");
        if (!write_frame(&save, save_tzx, 0x00, HEADER_SIZE)
            || f_write(&save, header, HEADER_SIZE, &w) != FR_OK || w != HEADER_SIZE
            || f_write(&save, &check, 1, &w) != FR_OK || w != 1) {
            f_close(&save);
            save_open = 0;
            return E_FULL;
        }
        return f_sync(&save) == FR_OK ? E_OK : E_IO;
    }
    if (f_write(&save, &check, 1, &w) != FR_OK || w != 1) {
        f_close(&save);
        save_open = 0;
        return E_FULL;
    }
    save_open = 0;
    return f_close(&save) == FR_OK ? E_OK : E_IO;    /* the data block ends the file */
}

/* ---- Commands ----------------------------------------------------------- */
void sdp_command(void)
{
    int cmd = hal_command();
    char name[NAME_MAX + 1];
    end_phase();
    hal_xfer(0);
    hal_res_clear();

    if (cmd == C_MOUNT) {
        mounted = 0;
    }
    int err = ensure_mounted();
    if (err) {
        hal_arg_clear();
        done(err);
        return;
    }

    switch (cmd) {
    case C_MOUNT:
        break;

    case C_DIRFIRST: {
        int len = hal_arg_pop();
        if (len < 0 || len > NAME_MAX) { err = E_BADNAME; break; }
        for (int i = 0; i < len; i++) dir_pattern[i] = (char) hal_arg_pop();
        dir_pattern[len] = '\0';
        if (len == 0) strcpy(dir_pattern, "*");
        f_closedir(&dir);
        memset(&dir, 0, sizeof dir);
        memset(&fno, 0, sizeof fno);
        dir_pass = 0;
    }   /* fall through */
    case C_DIRNEXT: {
        int found = dir_entry();
        if (found < 0) { err = -found; break; }
        push_entry(found);
        break;
    }

    case C_CHDIR:
        err = arg_name(name) ? fr_error(f_chdir(name)) : E_BADNAME;
        break;
    case C_DELETE:
        err = arg_name(name) ? fr_error(f_unlink(name)) : E_BADNAME;
        break;
    case C_FREE: {
        DWORD clusters;
        FATFS *pfs;
        err = fr_error(f_getfree("", &clusters, &pfs));
        if (!err) push_u32((uint32_t) ((uint64_t) clusters * pfs->csize * 512 / 1024));
        break;
    }

    case C_OPENR:
    case C_OPENW:
        close_file();                    /* opening closes a file left open */
        if (!arg_name(name)) { err = E_BADNAME; break; }
        err = fr_error(f_open(&file, name, cmd == C_OPENR ? FA_READ : FA_WRITE | FA_CREATE_ALWAYS));
        if (err) break;
        file_mode = cmd == C_OPENR ? 1 : 2;
        if (cmd == C_OPENR) {
            FSIZE_t s = f_size(&file);
            push_u32(s > 0xFFFFFFFFu ? 0xFFFFFFFFu : (uint32_t) s);
        }
        break;

    case C_READ: {
        int count = arg_u16();
        if (count < 0 || count > XFER_MAX) { err = E_TOOLARGE; break; }
        if (file_mode != 1) { err = E_NOTOPEN; break; }
        FSIZE_t avail = f_size(&file) - f_tell(&file);
        uint32_t n = avail < (FSIZE_t) count ? (uint32_t) avail : (uint32_t) count;
        hal_res_push(n & 0xFF);
        hal_res_push(n >> 8);
        if (n == 0) break;
        unsigned first = n > CHUNK ? CHUNK : n;
        phase = P_READ;
        phase_left = n - first;
        if (!push_chunk(&file, first)) { err = E_IO; break; }
        hal_xfer(2 + first);             /* the count, then the first chunk */
        break;
    }
    case C_WRITE: {
        int count = arg_u16();
        if (count < 0 || count > XFER_MAX) { err = E_TOOLARGE; break; }
        if (file_mode != 2) { err = E_NOTOPEN; break; }
        if (count == 0) break;
        phase = P_WRITE;
        chunk_len = count > CHUNK ? CHUNK : count;
        phase_left = count - chunk_len;
        hal_xfer(chunk_len);
        break;
    }
    case C_CLOSE:
        if (!file_mode) { err = E_NOTOPEN; break; }
        err = fr_error(f_close(&file));
        file_mode = 0;
        break;

    case C_TINSERT: {
        if (!arg_name(name)) { err = E_BADNAME; break; }
        static const char *const ext[] = { "", ".tap", ".tzx" };
        char path[sizeof tape_path];
        FILINFO info;
        err = E_NOTFOUND;
        for (int i = 0; i < 3 && err; i++) {
            strcpy(path, name);
            strcat(path, ext[i]);
            if (f_stat(path, &info) == FR_OK && !(info.fattrib & AM_DIR)) {
                strcpy(tape_path, path);
                tape_tzx = has_ext(path, ".tzx");
                tape_pos = 0;
                after_header = 0;
                searching = 0;
                err = E_OK;
            }
        }
        break;                           /* not found: the tape already in stays */
    }
    case C_TEJECT:
        tape_path[0] = '\0';
        searching = 0;
        break;
    case C_TREAD:
        tread();
        hal_arg_clear();
        return;
    case C_TWRITE:
        twrite();
        hal_arg_clear();
        return;

    default:
        err = E_BADNAME;
        break;
    }
    hal_arg_clear();
    done(err);
}

/* ---- Data phase ---------------------------------------------------------- */
void sdp_xfer(void)
{
    UINT w;
    switch (phase) {
    case P_READ:
        if (phase_left == 0) {
            phase = P_NONE;
            done(E_OK);
            return;
        }
        {
            unsigned n = phase_left > CHUNK ? CHUNK : phase_left;
            phase_left -= n;
            if (!push_chunk(&file, n)) { done(E_IO); return; }
            hal_ready(flags());
        }
        return;

    case P_WRITE:
        for (unsigned i = 0; i < chunk_len; i++) buf[i] = (uint8_t) hal_arg_pop();
        if (f_write(&file, buf, chunk_len, &w) != FR_OK || w != chunk_len) {
            done(E_FULL);
            return;
        }
        if (phase_left == 0) {
            phase = P_NONE;
            done(fr_error(f_sync(&file)));
            return;
        }
        chunk_len = phase_left > CHUNK ? CHUNK : phase_left;
        phase_left -= chunk_len;
        hal_xfer(chunk_len);
        hal_ready(flags());
        return;

    case P_TREAD:
        if (phase_left == 0) {           /* all the bytes moved: the checksum */
            uint8_t sum;
            int ok = read_exact(&tfile, &sum, 1) && sum == check;
            end_phase();
            done(ok ? E_OK : E_BADBLOCK);
            return;
        }
        {
            unsigned n = phase_left > CHUNK ? CHUNK : phase_left;
            phase_left -= n;
            if (!push_chunk(&tfile, n)) { end_phase(); done(E_BADBLOCK); return; }
            hal_ready(flags());
        }
        return;

    case P_TWRITE:
        if (tw_len) {
            unsigned done_bytes = tw_len - phase_left - chunk_len;
            for (unsigned i = 0; i < chunk_len; i++) {
                int b = hal_arg_pop();
                check ^= (uint8_t) b;
                if (tw_flag == 0x00) {
                    if (done_bytes + i < HEADER_SIZE) header[done_bytes + i] = (uint8_t) b;
                } else {
                    buf[i] = (uint8_t) b;
                }
            }
            if (tw_flag != 0x00
                && (f_write(&save, buf, chunk_len, &w) != FR_OK || w != chunk_len)) {
                f_close(&save);
                save_open = 0;
                phase = P_NONE;
                done(E_FULL);
                return;
            }
        }
        if (phase_left == 0) {
            phase = P_NONE;
            done(twrite_end());
            return;
        }
        chunk_len = phase_left > CHUNK ? CHUNK : phase_left;
        phase_left -= chunk_len;
        hal_xfer(chunk_len);
        hal_ready(flags());
        return;

    default:
        hal_ready(flags());              /* a stray count: nothing to do */
        return;
    }
}

void sdp_init(void)
{
    mounted = 0;
    file_mode = 0;
    tape_path[0] = '\0';
    save_open = 0;
    phase = P_NONE;
    hal_ready(0);
}
