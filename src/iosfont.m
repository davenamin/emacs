/* Core Text font driver for the iOS port of GNU Emacs.
   Copyright (C) 2026 Free Software Foundation, Inc.

This file is part of GNU Emacs.

GNU Emacs is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or (at
your option) any later version.

GNU Emacs is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.  */

/* A real font driver, built directly on Core Text -- the same API the
   macOS macfont.m driver rides, minus the AppKit/NSFont and ScreenFont
   machinery that only exists to bridge Emacs into AppKit's drawing and
   screen-metrics model.  The iOS port paints into its own bitmap
   context (iosterm.m / ios.m), so Core Text draws straight into it and
   no bridge layer is needed.

   Fonts are resolved through UIFont, which applies Apple's own font
   matching for a family / weight / slant / spacing request; the
   resolved face's PostScript name is stashed in the entity so open can
   recreate the exact CTFontRef.  Glyph indices, advances, and bounding
   boxes come from Core Text, so proportional fonts, multiple families,
   and real (not synthesised) bold and italic all work.  */

#include <config.h>

#ifdef HAVE_IOS

#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>

#include <math.h>
#include <string.h>
#include <strings.h>

#include "lisp.h"
#include "character.h"
#include "frame.h"
#include "font.h"
#include "fontset.h"
#include "composite.h"
#include "iosterm.h"

extern struct font_driver ios_font_driver;
extern void ios_launch_log (NSString *msg);

/* Entity extra-alist key under which list/match stash the resolved
   face's PostScript name, so open can recreate the exact CTFontRef.  */
static Lisp_Object Qios_psname;

/* Per-open-font extra data: the retained CTFontRef and the spacing
   class.  A struct font must come first so (struct ios_font_info *)
   font casts work.  */
struct ios_font_info
{
  struct font font;
  CTFontRef ctfont;     /* +1 retained; released in close.  */
  int spacing;          /* FONT_SPACING_MONO or _PROPORTIONAL.  */
};

/* ------------------------------------------------------------------ */
/* Small helpers.                                                     */
/* ------------------------------------------------------------------ */

/* Store the UTF-32 character C as one or two UTF-16 code units in
   UNICHARS; return the count.  Mirrors macfont's helper.  */
static CFIndex
ios_utf32_to_utf16 (UTF32Char c, UniChar unichars[2])
{
  if (c < 0x10000)
    {
      unichars[0] = (UniChar) c;
      return 1;
    }
  c -= 0x10000;
  unichars[0] = (UniChar) ((c >> 10) + 0xD800);
  unichars[1] = (UniChar) ((c & 0x3FF) + 0xDC00);
  return 2;
}

/* Emacs numeric styles: normal weight 80, bold 200; normal slant 100,
   italic 200.  Treat semi-bold and up as bold, and any real oblique as
   italic.  A missing property reads as -1, i.e. unspecified.  */
static bool
ios_spec_wants_bold (Lisp_Object spec)
{
  int w = FONT_WEIGHT_NUMERIC (spec);
  return w >= 150;
}

static bool
ios_spec_wants_italic (Lisp_Object spec)
{
  int s = FONT_SLANT_NUMERIC (spec);
  return s >= 150;
}

static bool
ios_spec_wants_mono (Lisp_Object spec)
{
  Lisp_Object sp = AREF (spec, FONT_SPACING_INDEX);
  if (FIXNUMP (sp))
    return XFIXNUM (sp) >= FONT_SPACING_MONO;
  /* No spacing given: decide from the family.  A missing family means
     the default (fixed-pitch) system font, and any family whose name
     mentions "mono" -- including the private ".AppleSystemUIFont-
     Monospaced" the default face inherits -- is monospaced.  */
  Lisp_Object fam = AREF (spec, FONT_FAMILY_INDEX);
  if (!SYMBOLP (fam) || NILP (fam))
    return true;
  const char *s = SSDATA (SYMBOL_NAME (fam));
  return (strcasestr (s, "mono") != NULL
          || strcasecmp (s, "fixed") == 0);
}

/* Turn a font spec/entity into a concrete UIFont, honouring family,
   weight, slant, and spacing.  Never returns nil: falls back to the
   monospaced system font so face realization always has a face.  */
static UIFont *
ios_resolve_uifont (Lisp_Object spec, CGFloat size)
{
  if (size < 1)
    size = 14;

  bool wantBold = ios_spec_wants_bold (spec);
  bool wantItalic = ios_spec_wants_italic (spec);
  bool wantMono = ios_spec_wants_mono (spec);

  Lisp_Object fam = AREF (spec, FONT_FAMILY_INDEX);
  NSString *family = nil;
  if (SYMBOLP (fam) && !NILP (fam))
    {
      const char *s = SSDATA (SYMBOL_NAME (fam));
      /* Emacs's generic families, and Apple's private dot-prefixed
         system families (the default face's ".AppleSystemUIFont*"),
         do not name a face fontWithName can open -- route them through
         the system-font constructors below, where weight is a real
         parameter.  */
      if (s[0] != '.'
          && strcasecmp (s, "monospace") && strcasecmp (s, "fixed")
          && strcasecmp (s, "sans serif") && strcasecmp (s, "sans-serif")
          && strcasecmp (s, "sans"))
        family = [NSString stringWithUTF8String:s];
    }

  UIFont *base = nil;
  if (family)
    {
      /* A named family (Courier, PingFang SC, ...).  fontWithName
         accepts a PostScript or full name; for a bare family name it
         can return nil, so fall back to a family-attribute descriptor,
         which is how the script-fallback fonts (CJK, emoji) resolve.
         Bold and italic are layered on as symbolic traits below.  */
      base = [UIFont fontWithName:family size:size];
      if (base == nil)
        {
          UIFontDescriptor *fd = [UIFontDescriptor
            fontDescriptorWithFontAttributes:
              @{ UIFontDescriptorFamilyAttribute : family }];
          if (fd)
            base = [UIFont fontWithDescriptor:fd size:size];
        }
      UIFontDescriptorSymbolicTraits want = 0;
      if (wantBold)   want |= UIFontDescriptorTraitBold;
      if (wantItalic) want |= UIFontDescriptorTraitItalic;
      if (base && want)
        {
          UIFontDescriptor *d = base.fontDescriptor;
          UIFontDescriptor *d2 = [d fontDescriptorWithSymbolicTraits:
                                    d.symbolicTraits | want];
          UIFont *styled = d2 ? [UIFont fontWithDescriptor:d2 size:size] : nil;
          if (styled)
            base = styled;
        }
    }
  if (base == nil)
    {
      /* System font: weight is a first-class parameter (the bold
         monospaced system font carries no Bold symbolic trait, so
         layering the trait would not make it bold).  Italic is still a
         trait, applied on top.  */
      UIFontWeight wt = wantBold ? UIFontWeightBold : UIFontWeightRegular;
      base = wantMono
        ? [UIFont monospacedSystemFontOfSize:size weight:wt]
        : [UIFont systemFontOfSize:size weight:wt];
      if (base && wantItalic)
        {
          UIFontDescriptor *d = base.fontDescriptor;
          UIFontDescriptor *d2 = [d fontDescriptorWithSymbolicTraits:
                                    d.symbolicTraits
                                    | UIFontDescriptorTraitItalic];
          UIFont *styled = d2 ? [UIFont fontWithDescriptor:d2 size:size] : nil;
          if (styled)
            base = styled;
        }
    }
  if (base == nil)
    base = [UIFont systemFontOfSize:size];
  return base;
}

/* Create a +1 CTFontRef for the PostScript name NAME at SIZE.  */
static CTFontRef
ios_ctfont_create (NSString *name, CGFloat size)
{
  if (name == nil || size < 1)
    return NULL;
  return CTFontCreateWithName ((__bridge CFStringRef) name, size, NULL);
}

/* Build a font entity describing UIFont UIF resolved for SPEC, stashing
   its PostScript name so open can recreate it.  */
static Lisp_Object
ios_uifont_entity (UIFont *uif, Lisp_Object spec)
{
  Lisp_Object entity = font_make_entity ();
  UIFontDescriptor *d = uif.fontDescriptor;
  UIFontDescriptorSymbolicTraits tr = d.symbolicTraits;

  /* Label from the request first.  Apple's system-font descriptors are
     opaque: the bold monospaced system font exposes neither its weight
     axis nor a Bold or MonoSpace symbolic trait, so the resolved UIFont
     cannot be trusted to report what it is, and a normal-labelled
     entity makes find-font reject a bold spec.  OR in the descriptor
     traits so a named family (Courier, ...) is still described
     truthfully when the spec left a property unset.  */
  bool isBold = ios_spec_wants_bold (spec)
                || (tr & UIFontDescriptorTraitBold);
  bool isItalic = ios_spec_wants_italic (spec)
                  || (tr & UIFontDescriptorTraitItalic);
  bool isMono = ios_spec_wants_mono (spec)
                || (tr & UIFontDescriptorTraitMonoSpace);

  ASET (entity, FONT_TYPE_INDEX, Qios);
  ASET (entity, FONT_FOUNDRY_INDEX, intern ("apple"));
  ASET (entity, FONT_FAMILY_INDEX,
        intern (uif.familyName.UTF8String));
  ASET (entity, FONT_ADSTYLE_INDEX, Qnil);
  ASET (entity, FONT_REGISTRY_INDEX, intern ("iso10646-1"));
  /* Scalable: size 0 lets open substitute the requested pixel size.  */
  ASET (entity, FONT_SIZE_INDEX, make_fixnum (0));
  ASET (entity, FONT_AVGWIDTH_INDEX, make_fixnum (0));
  ASET (entity, FONT_SPACING_INDEX,
        make_fixnum (isMono ? FONT_SPACING_MONO : FONT_SPACING_PROPORTIONAL));
  FONT_SET_STYLE (entity, FONT_WEIGHT_INDEX, isBold ? Qbold : Qnormal);
  FONT_SET_STYLE (entity, FONT_SLANT_INDEX, isItalic ? Qitalic : Qnormal);
  FONT_SET_STYLE (entity, FONT_WIDTH_INDEX, Qnormal);

  /* fontName is the PostScript name; recreate the exact face from it.  */
  font_put_extra (entity, Qios_psname,
                  build_string (uif.fontName.UTF8String));
  return entity;
}

/* ------------------------------------------------------------------ */
/* Metrics.                                                           */
/* ------------------------------------------------------------------ */

static int
ios_glyph_advance (CTFontRef ctfont, CGGlyph glyph)
{
  double w = CTFontGetAdvancesForGlyphs (ctfont, kCTFontOrientationDefault,
                                         &glyph, NULL, 1);
  int iw = (int) lround (w);
  return iw > 0 ? iw : 1;
}

static void
ios_font_fill_metrics (struct font *font, CTFontRef ctfont, int spacing)
{
  CGFloat ascent  = CTFontGetAscent (ctfont);
  CGFloat descent = CTFontGetDescent (ctfont);
  CGFloat leading = CTFontGetLeading (ctfont);

  font->pixel_size = (int) lround (CTFontGetSize (ctfont));
  font->ascent  = (int) (ascent + 0.5f);
  font->descent = (int) (descent + leading + 0.5f);
  font->height  = font->ascent + font->descent;
  if (font->height < 1)
    font->height = 1;

  /* Space width, and average width over printable ASCII.  */
  UniChar sp = ' ';
  CGGlyph spg = 0;
  int space_w = font->pixel_size;
  if (CTFontGetGlyphsForCharacters (ctfont, &sp, &spg, 1) && spg)
    space_w = ios_glyph_advance (ctfont, spg);
  if (space_w < 1)
    space_w = 1;
  font->space_width = space_w;

  long total = space_w;
  int n = 1, i;
  for (i = 1; i < 95; i++)
    {
      UniChar ch = (UniChar) (' ' + i);
      CGGlyph g = 0;
      if (!CTFontGetGlyphsForCharacters (ctfont, &ch, &g, 1) || !g)
        continue;
      total += ios_glyph_advance (ctfont, g);
      n++;
    }
  font->average_width = (int) (total / n);
  if (font->average_width < 1)
    font->average_width = 1;

  /* Core Text exposes no cheap min/max advance; monospace fonts have a
     single width, and for proportional fonts the space width is a safe
     conservative minimum (matches macfont's own compromise).  */
  font->min_width = font->space_width;
  font->max_width = (spacing == FONT_SPACING_MONO)
                    ? font->space_width
                    : font->average_width;

  CGFloat up = CTFontGetUnderlinePosition (ctfont);
  CGFloat ut = CTFontGetUnderlineThickness (ctfont);
  font->underline_position = (int) (-up + 0.5f);
  font->underline_thickness = (int) (ut + 0.5f);
  if (font->underline_thickness < 1)
    font->underline_thickness = 1;

  font->baseline_offset = 0;
  font->relative_compose = 0;
  font->default_ascent = 0;
  font->vertical_centering = 0;
}

/* ------------------------------------------------------------------ */
/* Driver hooks.                                                      */
/* ------------------------------------------------------------------ */

static Lisp_Object
ios_font_get_cache (struct frame *f)
{
  struct ios_display_info *dpyinfo = FRAME_DISPLAY_INFO (f);
  return dpyinfo->name_list_element;
}

/* Resolve SPEC to one concrete face via UIFont (Apple's matcher) and
   return a single entity for it.  We resolve rather than enumerate:
   Apple's matcher already picks the best face for the requested family
   and traits, so handing Emacs that one candidate opens exactly it.  */
static Lisp_Object
ios_font_list (struct frame *f, Lisp_Object font_spec)
{
  (void) f;
  UIFont *uif = ios_resolve_uifont (font_spec, 14);
  if (uif == nil)
    return Qnil;
  return list1 (ios_uifont_entity (uif, font_spec));
}

static Lisp_Object
ios_font_match (struct frame *f, Lisp_Object font_spec)
{
  (void) f;
  UIFont *uif = ios_resolve_uifont (font_spec, 14);
  if (uif == nil)
    return Qnil;
  return ios_uifont_entity (uif, font_spec);
}

static Lisp_Object
ios_font_list_family (struct frame *f)
{
  (void) f;
  Lisp_Object list = Qnil;
  for (NSString *fam in [UIFont familyNames])
    list = Fcons (intern (fam.UTF8String), list);
  return list;
}

static Lisp_Object
ios_font_open (struct frame *f, Lisp_Object font_entity, int pixel_size)
{
  int requested = pixel_size;
  /* Degenerate sizes collapse the frame layout; a size-less spec whose
     pixel field decodes tiny falls back to the frame font.  */
  if (pixel_size < 6)
    {
      static bool logged = false;
      if (requested > 0 && !logged)
        {
          logged = true;
          ios_launch_log ([NSString stringWithFormat:
            @"ios_font_open: anomalous size=%d", requested]);
        }
      pixel_size = (FRAME_FONT (f)) ? FRAME_FONT (f)->pixel_size : 14;
      if (pixel_size < 6)
        pixel_size = 14;
    }

  /* Recreate the exact face from the stashed PostScript name; fall back
     to resolving the entity afresh if it is missing (e.g. a fontset
     fallback entity).  */
  CTFontRef ctfont = NULL;
  Lisp_Object val = assq_no_quit (Qios_psname,
                                  AREF (font_entity, FONT_EXTRA_INDEX));
  if (CONSP (val) && STRINGP (XCDR (val)))
    {
      NSString *name = [NSString stringWithUTF8String:SSDATA (XCDR (val))];
      ctfont = ios_ctfont_create (name, pixel_size);
    }
  if (ctfont == NULL)
    {
      UIFont *uif = ios_resolve_uifont (font_entity, pixel_size);
      ctfont = ios_ctfont_create (uif.fontName, pixel_size);
    }
  if (ctfont == NULL)
    return Qnil;

  Lisp_Object font_object
    = font_make_object (VECSIZE (struct ios_font_info),
                        font_entity, pixel_size);
  ASET (font_object, FONT_TYPE_INDEX, Qios);

  struct ios_font_info *info
    = (struct ios_font_info *) XFONT_OBJECT (font_object);
  struct font *font = &info->font;
  font->driver = &ios_font_driver;

  Lisp_Object sp = AREF (font_entity, FONT_SPACING_INDEX);
  info->spacing = (FIXNUMP (sp) && XFIXNUM (sp) >= FONT_SPACING_MONO)
                  ? FONT_SPACING_MONO : FONT_SPACING_PROPORTIONAL;
  info->ctfont = ctfont;   /* keep the +1 reference */

  ios_font_fill_metrics (font, ctfont, info->spacing);

  font->props[FONT_NAME_INDEX] = Ffont_xlfd_name (font_object, Qnil, Qt);
  return font_object;
}

static void
ios_font_close (struct font *font)
{
  struct ios_font_info *info = (struct ios_font_info *) font;
  if (info->ctfont)
    {
      CFRelease (info->ctfont);
      info->ctfont = NULL;
    }
}

static int
ios_font_has_char (Lisp_Object font, int c)
{
  if (c < 0 || c > MAX_UNICODE_CHAR)
    return false;
  /* On an entity we have no open face yet; let encode_char decide.  */
  if (FONT_ENTITY_P (font))
    return -1;
  struct ios_font_info *info
    = (struct ios_font_info *) XFONT_OBJECT (font);
  UniChar u[2];
  CGGlyph g[2];
  CFIndex n = ios_utf32_to_utf16 ((UTF32Char) c, u);
  return CTFontGetGlyphsForCharacters (info->ctfont, u, g, n) ? 1 : 0;
}

static unsigned
ios_font_encode_char (struct font *font, int c)
{
  struct ios_font_info *info = (struct ios_font_info *) font;
  UniChar u[2];
  CGGlyph g[2] = { 0, 0 };
  CFIndex n = ios_utf32_to_utf16 ((UTF32Char) c, u);
  if (!CTFontGetGlyphsForCharacters (info->ctfont, u, g, n) || g[0] == 0)
    return FONT_INVALID_CODE;
  return g[0];
}

static void
ios_font_text_extents (struct font *font,
                       const unsigned *code, int nglyphs,
                       struct font_metrics *metrics)
{
  struct ios_font_info *info = (struct ios_font_info *) font;
  memset (metrics, 0, sizeof *metrics);
  if (nglyphs <= 0)
    return;

  int width = 0, i;
  for (i = 0; i < nglyphs; i++)
    {
      CGGlyph g = (CGGlyph) code[i];
      CGRect bounds = CTFontGetBoundingRectsForGlyphs
        (info->ctfont, kCTFontOrientationDefault, &g, NULL, 1);
      int adv = ios_glyph_advance (info->ctfont, g);
      int lb = (int) floor (CGRectGetMinX (bounds));
      int rb = (int) ceil (CGRectGetMaxX (bounds));
      int as = (int) ceil (CGRectGetMaxY (bounds));
      int de = (int) ceil (-CGRectGetMinY (bounds));

      if (width + lb < metrics->lbearing)
        metrics->lbearing = width + lb;
      if (width + rb > metrics->rbearing)
        metrics->rbearing = width + rb;
      if (as > metrics->ascent)
        metrics->ascent = as;
      if (de > metrics->descent)
        metrics->descent = de;
      width += adv;
    }
  metrics->width = width;
}

/* ------------------------------------------------------------------ */
/* Complex-text shaping via Core Text.                                */
/* ------------------------------------------------------------------ */

/* Shape LGSTRING with Core Text and fill its LGLYPH vector, returning
   the glyph count used, or nil to let the caller fall back to the
   unshaped per-character layout.  This is what turns ligatures and
   complex scripts (Arabic, Indic) into correct glyph runs.  Adapted
   from macfont's CTLine/CTRun shaper without the AppKit ScreenFont
   path, and defensive throughout: any uncertainty returns nil rather
   than a partial or wrong result, so a shaping miss never corrupts the
   display -- it just renders unshaped.  */
static Lisp_Object
ios_font_shape (Lisp_Object lgstring, Lisp_Object direction)
{
  (void) direction;
  Lisp_Object font_object = LGSTRING_FONT (lgstring);
  if (!FONT_OBJECT_P (font_object))
    return Qnil;
  struct font *font = XFONT_OBJECT (font_object);
  if (font->driver != &ios_font_driver)
    return Qnil;
  CTFontRef ctfont = ((struct ios_font_info *) font)->ctfont;
  if (ctfont == NULL)
    return Qnil;

  ptrdiff_t glyph_len = LGSTRING_GLYPH_LEN (lgstring);
  if (glyph_len <= 0)
    return Qnil;

  /* Leading run of real characters.  */
  ptrdiff_t nchars = 0;
  while (nchars < glyph_len && FIXNUMP (LGSTRING_CHAR (lgstring, nchars)))
    nchars++;
  if (nchars == 0)
    return Qnil;

  /* UTF-16 string plus a code-unit -> character-index map, so a glyph's
     Core Text string index resolves back to the Emacs character.  */
  UniChar *u16 = xmalloc (sizeof *u16 * nchars * 2);
  ptrdiff_t *u16char = xmalloc (sizeof *u16char * nchars * 2);
  CFIndex u16len = 0;
  for (ptrdiff_t i = 0; i < nchars; i++)
    {
      UniChar tmp[2];
      CFIndex k = ios_utf32_to_utf16 ((UTF32Char) XFIXNUM (LGSTRING_CHAR
                                                           (lgstring, i)),
                                      tmp);
      for (CFIndex j = 0; j < k; j++)
        {
          u16[u16len] = tmp[j];
          u16char[u16len] = i;
          u16len++;
        }
    }

  CFStringRef string = CFStringCreateWithCharacters (NULL, u16, u16len);
  if (string == NULL)
    {
      xfree (u16);
      xfree (u16char);
      return Qnil;
    }

  /* This font, kerning off (Emacs owns positioning).  */
  float zero = 0;
  CFNumberRef kern = CFNumberCreate (NULL, kCFNumberFloatType, &zero);
  CFStringRef keys[] = { kCTFontAttributeName, kCTKernAttributeName };
  CFTypeRef vals[] = { ctfont, kern };
  CFDictionaryRef attrs
    = CFDictionaryCreate (NULL, (const void **) keys, (const void **) vals,
                          2, &kCFTypeDictionaryKeyCallBacks,
                          &kCFTypeDictionaryValueCallBacks);
  CFAttributedStringRef astr
    = attrs ? CFAttributedStringCreate (NULL, string, attrs) : NULL;
  CTLineRef line = astr ? CTLineCreateWithAttributedString (astr) : NULL;
  if (kern) CFRelease (kern);
  if (attrs) CFRelease (attrs);
  if (astr) CFRelease (astr);
  CFRelease (string);
  if (line == NULL)
    {
      xfree (u16);
      xfree (u16char);
      return Qnil;
    }

  CFArrayRef runs = CTLineGetGlyphRuns (line);
  CFIndex nruns = runs ? CFArrayGetCount (runs) : 0;
  ptrdiff_t out = 0;
  bool ok = nruns > 0;
  double total_advance = 0;

  for (CFIndex r = 0; r < nruns && ok; r++)
    {
      CTRunRef run = CFArrayGetValueAtIndex (runs, r);
      /* A run Core Text drew in a substitute font must fall back to the
         fontset, not be shaped here.  */
      CFDictionaryRef ra = CTRunGetAttributes (run);
      CTFontRef rf = ra ? CFDictionaryGetValue (ra, kCTFontAttributeName)
                        : NULL;
      if (rf && !CFEqual (rf, ctfont))
        {
          ok = false;
          break;
        }

      CFIndex gc = CTRunGetGlyphCount (run);
      for (CFIndex gi = 0; gi < gc; gi++)
        {
          if (out >= glyph_len)
            {
              ok = false;
              break;
            }
          CFRange one = CFRangeMake (gi, 1);
          CGGlyph g = 0;
          CGPoint pos = { 0, 0 };
          CFIndex sidx = 0;
          CTRunGetGlyphs (run, one, &g);
          CTRunGetPositions (run, one, &pos);
          CTRunGetStringIndices (run, one, &sidx);
          double gadv = CTRunGetTypographicBounds (run, one, NULL, NULL, NULL);

          double max_x = pos.x + gadv;
          if (max_x < total_advance)
            max_x = total_advance;
          double advance_delta = pos.x - total_advance;
          double advance = max_x - total_advance;
          total_advance = max_x;

          ptrdiff_t ci = (sidx >= 0 && sidx < u16len) ? u16char[sidx] : 0;
          int c = XFIXNUM (LGSTRING_CHAR (lgstring, ci));

          Lisp_Object lglyph = LGSTRING_GLYPH (lgstring, out);
          if (NILP (lglyph))
            {
              lglyph = LGLYPH_NEW ();
              LGSTRING_SET_GLYPH (lgstring, out, lglyph);
            }
          LGLYPH_SET_FROM (lglyph, ci);
          LGLYPH_SET_TO (lglyph, ci);
          LGLYPH_SET_CHAR (lglyph, c);
          LGLYPH_SET_CODE (lglyph, g);

          unsigned code = g;
          struct font_metrics m;
          ios_font_text_extents (font, &code, 1, &m);
          LGLYPH_SET_WIDTH (lglyph, m.width);
          LGLYPH_SET_LBEARING (lglyph, m.lbearing);
          LGLYPH_SET_RBEARING (lglyph, m.rbearing);
          LGLYPH_SET_ASCENT (lglyph, m.ascent);
          LGLYPH_SET_DESCENT (lglyph, m.descent);

          int xoff = (int) lround (advance_delta);
          int yoff = (int) lround (-pos.y);
          int wadjust = (int) lround (advance);
          if (xoff != 0 || yoff != 0 || wadjust != m.width)
            LGLYPH_SET_ADJUSTMENT (lglyph,
                                   CALLN (Fvector, make_fixnum (xoff),
                                          make_fixnum (yoff),
                                          make_fixnum (wadjust)));
          out++;
        }
    }

  CFRelease (line);
  xfree (u16);
  xfree (u16char);
  if (!ok || out == 0)
    return Qnil;
  return make_fixnum (out);
}

#ifdef HAVE_WINDOW_SYSTEM
/* The RIF (ios_draw_glyph_string in iosterm.m) draws glyphs directly
   into the backing store; nothing routes through the driver draw hook,
   so it stays a stub.  */
static int
ios_font_draw (struct glyph_string *s, int from, int to,
               int x, int y, bool with_background)
{
  (void) s; (void) from; (void) to;
  (void) x; (void) y; (void) with_background;
  return 0;
}
#endif

/* Expose the retained CTFontRef backing FONT so the renderer in
   iosterm.m can draw glyphs.  Returned as void * so the plain-C header
   need not know Core Text; NULL for a font that is not ours.  */
void *
ios_font_ctfont (struct font *font)
{
  if (font == NULL || font->driver != &ios_font_driver)
    return NULL;
  return (void *) ((struct ios_font_info *) font)->ctfont;
}

struct font_driver ios_font_driver =
  {
    .type            = LISPSYM_INITIALLY (Qios),
    .case_sensitive  = false,
    .get_cache       = ios_font_get_cache,
    .list            = ios_font_list,
    .match           = ios_font_match,
    .list_family     = ios_font_list_family,
    .open_font       = ios_font_open,
    .close_font      = ios_font_close,
    .has_char        = ios_font_has_char,
    .encode_char     = ios_font_encode_char,
    .text_extents    = ios_font_text_extents,
    .shape           = ios_font_shape,
#ifdef HAVE_WINDOW_SYSTEM
    .draw            = ios_font_draw,
#endif
  };

void
syms_of_iosfont (void)
{
  /* Entity extra key for the resolved PostScript name.  Interned, so
     the obarray keeps it live; no staticpro needed.  */
  Qios_psname = intern_c_string (":ios-psname");

  register_font_driver (&ios_font_driver, NULL);
}

#endif /* HAVE_IOS */
