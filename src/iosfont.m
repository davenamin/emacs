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

  /* Describe what the font ACTUALLY is, read through Core Text.  The
     UIFontDescriptor is opaque for Apple's system fonts (it reports no
     weight axis and no Bold/MonoSpace symbolic trait), but
     CTFontCopyTraits -- the call macfont.m uses -- does expose the
     numeric weight and slant, so the bold monospaced system font is
     labelled bold and find-font accepts a bold spec.  */
  bool isBold = false, isItalic = false, isMono = false;
  CTFontRef ct = CTFontCreateWithName ((__bridge CFStringRef) uif.fontName,
                                       uif.pointSize > 0 ? uif.pointSize : 14,
                                       NULL);
  if (ct)
    {
      CFDictionaryRef traits = CTFontCopyTraits (ct);
      if (traits)
        {
          int64_t sym = 0;
          double v;
          CFNumberRef n = CFDictionaryGetValue (traits, kCTFontSymbolicTrait);
          if (n)
            CFNumberGetValue (n, kCFNumberSInt64Type, &sym);
          isBold = (sym & kCTFontTraitBold) != 0;
          isItalic = (sym & kCTFontTraitItalic) != 0;
          isMono = (sym & kCTFontTraitMonoSpace) != 0;
          /* The symbolic Bold/Italic bits are often unset on the system
             fonts even when the weight/slant axes say otherwise.  */
          n = CFDictionaryGetValue (traits, kCTFontWeightTrait);
          if (n && CFNumberGetValue (n, kCFNumberDoubleType, &v) && v >= 0.25)
            isBold = true;
          n = CFDictionaryGetValue (traits, kCTFontSlantTrait);
          if (n && CFNumberGetValue (n, kCFNumberDoubleType, &v) && v > 0.01)
            isItalic = true;
          CFRelease (traits);
        }
      CFRelease (ct);
    }
  /* Spacing: Core Text likewise omits the MonoSpace bit for the system
     mono font, so fall back to the family-name heuristic.  */
  if (!isMono)
    isMono = ios_spec_wants_mono (spec);

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

  /* Fixed-pitch fast path: every glyph advances by the cell width, so
     skip the per-glyph Core Text metric round-trips entirely.  This is
     the default font and every code buffer -- macfont caches per-glyph
     metrics; for a monospaced font the cell width is all we need.  */
  if (info->spacing == FONT_SPACING_MONO)
    {
      metrics->width = nglyphs * font->space_width;
      metrics->lbearing = 0;
      metrics->rbearing = metrics->width;
      metrics->ascent = font->ascent;
      metrics->descent = font->descent;
      return;
    }

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

/* Faithful port of macfont's CTLine/CTRun shaper (minus the AppKit
   ScreenFont path).  The three-pass composed-character-range
   computation gives each glyph a correct from/to span even for
   ligatures and Indic conjuncts, and the right-to-left permutation puts
   Arabic and Hebrew glyphs back in logical order -- both needed for
   cursor motion and editing to line up with the display.  The composite
   draw path in iosterm.m mirrors ns_draw_composite_glyph_string, the
   same consumer this shaper feeds on macOS.  Defensive: a substituted
   run (left for the fontset) or any inconsistency returns nil, so a
   shaping miss renders unshaped rather than wrong.  */

/* Per-glyph shaping result, mirroring macfont's mac_glyph_layout.  */
struct ios_glyph_layout
{
  CFRange comp_range;    /* composed-character range, UTF-16 indices */
  CFIndex string_index;  /* UTF-16 index of the glyph's first char   */
  CGGlyph glyph_id;
  CGFloat advance;
  CGFloat advance_delta;
  CGFloat baseline_delta;
};

/* A CTLine over STRING in FONT with kerning off (Emacs owns spacing).  */
static CTLineRef
ios_ct_line (CFStringRef string, CTFontRef font)
{
  float zero = 0;
  CFNumberRef kern = CFNumberCreate (NULL, kCFNumberFloatType, &zero);
  CFStringRef keys[] = { kCTFontAttributeName, kCTKernAttributeName };
  CFTypeRef vals[] = { font, kern };
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
  return line;
}

/* Shape STRING with FONT into GLYPH_LAYOUTS (room for GLYPH_LEN),
   returning the glyph count, or 0 to fall back.  Ported from
   mac_font_shape.  */
static CFIndex
ios_ct_shape (CTFontRef font, CFStringRef string,
              struct ios_glyph_layout *glyph_layouts, CFIndex glyph_len)
{
  CFIndex used, result = 0;
  CTLineRef ctline = ios_ct_line (string, font);
  if (ctline == NULL)
    return 0;

  used = CTLineGetGlyphCount (ctline);
  if (used > 0 && used <= glyph_len)
    {
      CFArrayRef ctruns = CTLineGetGlyphRuns (ctline);
      CFIndex k, ctrun_count = CFArrayGetCount (ctruns);
      CGFloat total_advance = 0;
      CFIndex total_glyph_count = 0;
      bool ok = true;

      for (k = 0; k < ctrun_count; k++)
        {
          CTRunRef ctrun = CFArrayGetValueAtIndex (ctruns, k);
          CFIndex i, min_location, glyph_count = CTRunGetGlyphCount (ctrun);
          struct ios_glyph_layout *glbuf = glyph_layouts + total_glyph_count;
          CFRange string_range, comp_range, range;
          CFIndex *permutation;

          /* A run drawn in a substitute font is left for the fontset;
             give up and let redisplay lay it out unshaped.  */
          CFDictionaryRef ra = CTRunGetAttributes (ctrun);
          CTFontRef rf = ra ? CFDictionaryGetValue (ra, kCTFontAttributeName)
                            : NULL;
          if (rf && !CFEqual (rf, font))
            {
              ok = false;
              break;
            }
          if (glyph_count == 0)
            continue;

          if (CTRunGetStatus (ctrun) & kCTRunStatusRightToLeft)
            permutation = xmalloc (sizeof (CFIndex) * glyph_count);
          else
            permutation = NULL;
#define RIGHT_TO_LEFT_P permutation

          /* First pass: per glyph, the composed-character range at its
             string index (comp_range is a temporary work area here).  */
          string_range = CTRunGetStringRange (ctrun);
          min_location = string_range.location + string_range.length;
          for (i = 0; i < glyph_count; i++)
            {
              struct ios_glyph_layout *gl = glbuf + glyph_count - i - 1;
              CFIndex glyph_index = RIGHT_TO_LEFT_P ? i : glyph_count - i - 1;
              CFRange rng;

              CTRunGetStringIndices (ctrun, CFRangeMake (glyph_index, 1),
                                     &gl->string_index);
              rng = CFStringGetRangeOfComposedCharactersAtIndex
                      (string, gl->string_index);
              gl->comp_range.location = min_location;
              gl->comp_range.length = rng.location + rng.length;
              if (rng.location < min_location)
                min_location = rng.location;
            }

          /* Second pass: group glyphs into composed-character ranges and
             build the right-to-left permutation.  */
          comp_range = CFRangeMake (string_range.location, 0);
          range = CFRangeMake (0, 0);
          while (1)
            {
              struct ios_glyph_layout *gl
                = glbuf + range.location + range.length;

              if (gl->comp_range.length
                  > comp_range.location + comp_range.length)
                comp_range.length
                  = gl->comp_range.length - comp_range.location;
              min_location = gl->comp_range.location;
              range.length++;

              if (min_location >= comp_range.location + comp_range.length)
                {
                  comp_range.length = min_location - comp_range.location;
                  for (i = 0; i < range.length; i++)
                    {
                      glbuf[range.location + i].comp_range = comp_range;
                      if (RIGHT_TO_LEFT_P)
                        permutation[range.location + i]
                          = range.location + range.length - i - 1;
                    }
                  comp_range = CFRangeMake (min_location, 0);
                  range.location += range.length;
                  range.length = 0;
                  if (range.location == glyph_count)
                    break;
                }
            }

          /* Third pass: glyph ids, positions, advances (permuted).  */
          for (range = CFRangeMake (0, 1); range.location < glyph_count;
               range.location++)
            {
              struct ios_glyph_layout *gl;
              CGPoint position;
              CGFloat max_x;

              if (!RIGHT_TO_LEFT_P)
                gl = glbuf + range.location;
              else
                {
                  CFIndex src = glyph_count - 1 - range.location;
                  CFIndex dest = permutation[src];

                  gl = glbuf + dest;
                  if (src < dest)
                    {
                      CFIndex tmp = gl->string_index;
                      gl->string_index = glbuf[src].string_index;
                      glbuf[src].string_index = tmp;
                    }
                }
              CTRunGetGlyphs (ctrun, range, &gl->glyph_id);
              CTRunGetPositions (ctrun, range, &position);
              max_x = position.x
                      + CTRunGetTypographicBounds (ctrun, range, NULL, NULL,
                                                   NULL);
              max_x = max (max_x, total_advance);
              gl->advance_delta = position.x - total_advance;
              gl->baseline_delta = position.y;
              gl->advance = max_x - total_advance;
              total_advance = max_x;
            }

          if (RIGHT_TO_LEFT_P)
            xfree (permutation);
#undef RIGHT_TO_LEFT_P

          total_glyph_count += glyph_count;
        }

      if (ok)
        result = used;
    }

  CFRelease (ctline);
  return result;
}

/* The font driver's shape hook.  Ported from macfont_shape.  */
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

  ptrdiff_t glyph_len = LGSTRING_GLYPH_LEN (lgstring), len, i, j;
  CFIndex nonbmp_len = 0;

  for (i = 0; i < glyph_len; i++)
    {
      Lisp_Object lglyph = LGSTRING_GLYPH (lgstring, i);
      if (NILP (lglyph))
        break;
      if (LGLYPH_CHAR (lglyph) >= 0x10000)
        nonbmp_len++;
    }
  len = i;
  if (len == 0)
    return Qnil;

  /* UTF-16 buffer, plus a sentinel-terminated list of the UTF-16 indices
     of non-BMP characters, to convert Core Text's UTF-16 offsets back to
     Emacs character indices.  */
  UniChar *unichars = xmalloc (sizeof *unichars * (len + nonbmp_len));
  CFIndex *nonbmp_indices = xmalloc (sizeof *nonbmp_indices * (nonbmp_len + 1));
  for (i = j = 0; i < len; i++)
    {
      UTF32Char c = LGLYPH_CHAR (LGSTRING_GLYPH (lgstring, i));
      if (ios_utf32_to_utf16 (c, unichars + i + j) > 1)
        nonbmp_indices[j++] = i + j;
    }
  nonbmp_indices[j] = len + j;   /* sentinel */

  /* NoCopy: the CFString references unichars, which therefore must
     outlive it and the glyph loop, so it is freed only at the end.  */
  CFStringRef string = CFStringCreateWithCharactersNoCopy
    (NULL, unichars, len + nonbmp_len, kCFAllocatorNull);
  CFIndex used = 0;
  struct ios_glyph_layout *layouts = NULL;
  if (string)
    {
      layouts = xmalloc (sizeof *layouts * glyph_len);
      used = ios_ct_shape (ctfont, string, layouts, glyph_len);
      CFRelease (string);
    }
  if (used == 0)
    {
      xfree (unichars);
      xfree (nonbmp_indices);
      xfree (layouts);
      return Qnil;
    }

  for (i = 0; i < used; i++)
    {
      Lisp_Object lglyph = LGSTRING_GLYPH (lgstring, i);
      struct ios_glyph_layout *gl = layouts + i;
      EMACS_INT from, to;
      struct font_metrics metrics;
      int xoff, yoff, wadjust;
      unsigned code;
      UTF32Char c;

      if (NILP (lglyph))
        {
          lglyph = LGLYPH_NEW ();
          LGSTRING_SET_GLYPH (lgstring, i, lglyph);
        }

      /* comp_range is in UTF-16 units; subtract the non-BMP units seen
         so far to recover Emacs character indices.  */
      from = gl->comp_range.location;
      j = 0;
      while (nonbmp_indices[j] < from)
        j++;
      from -= j;
      LGLYPH_SET_FROM (lglyph, from);

      to = gl->comp_range.location + gl->comp_range.length;
      while (nonbmp_indices[j] < to)
        j++;
      to -= j;
      LGLYPH_SET_TO (lglyph, to - 1);

      /* LGLYPH_CHAR: the base character, or 0 to mark a non-trivial
         composition (the glyph is not the base char's own glyph).  */
      if (unichars[gl->string_index] >= 0xD800
          && unichars[gl->string_index] < 0xDC00)
        c = (((unichars[gl->string_index] - 0xD800) << 10)
             + (unichars[gl->string_index + 1] - 0xDC00) + 0x10000);
      else
        c = unichars[gl->string_index];
      {
        UniChar u2[2];
        CGGlyph g2[2] = { 0, 0 };
        CFIndex kk = ios_utf32_to_utf16 (c, u2);
        if (!CTFontGetGlyphsForCharacters (ctfont, u2, g2, kk)
            || g2[0] != gl->glyph_id)
          c = 0;
      }
      LGLYPH_SET_CHAR (lglyph, c);
      LGLYPH_SET_CODE (lglyph, gl->glyph_id);

      code = gl->glyph_id;
      ios_font_text_extents (font, &code, 1, &metrics);
      LGLYPH_SET_WIDTH (lglyph, metrics.width);
      LGLYPH_SET_LBEARING (lglyph, metrics.lbearing);
      LGLYPH_SET_RBEARING (lglyph, metrics.rbearing);
      LGLYPH_SET_ASCENT (lglyph, metrics.ascent);
      LGLYPH_SET_DESCENT (lglyph, metrics.descent);

      xoff = (int) lround (gl->advance_delta);
      yoff = (int) lround (-gl->baseline_delta);
      wadjust = (int) lround (gl->advance);
      if (xoff != 0 || yoff != 0 || wadjust != metrics.width)
        LGLYPH_SET_ADJUSTMENT (lglyph,
                               CALLN (Fvector, make_fixnum (xoff),
                                      make_fixnum (yoff),
                                      make_fixnum (wadjust)));
    }

  xfree (unichars);
  xfree (nonbmp_indices);
  xfree (layouts);
  return make_fixnum (used);
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
