/* iOS font driver shim for GNU Emacs.
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

/* Minimal font driver for the iOS port.  Bridges UIFont's
   monospaced system font to a struct font.  Only the hooks required
   to keep init_frame_faces -> realize_basic_faces ->
   realize_default_face from crashing are implemented; glyph
   drawing is a no-op until the EmacsUIView in iosterm.m grows a
   CALayer-backed renderer.  */

#include <config.h>

#ifdef HAVE_IOS

#import <UIKit/UIKit.h>

#include <math.h>

#include "lisp.h"
#include "frame.h"
#include "font.h"
#include "iosterm.h"

/* Forward declaration so open_font can store its address into
   font->driver before the driver itself is defined below.  */
extern struct font_driver ios_font_driver;
extern void ios_launch_log (NSString *msg);

/* Per-open-font extra data: the UIFont retained reference (needed
   later to ask Core Text for glyph runs).  Lives after struct font
   in the font-object vector so font_make_object's VECSIZE math
   accounts for it.  */
struct ios_font_info
{
  struct font font;
  void *uifont; /* (__bridge_retained) UIFont * */
};

static UIFont *
ios_font_default (CGFloat size)
{
  if (size <= 0)
    size = 14;
  UIFont *f = [UIFont monospacedSystemFontOfSize:size
                                          weight:UIFontWeightRegular];
  return f ? f : [UIFont systemFontOfSize:size];
}

static void
ios_font_fill_metrics (struct font *font, UIFont *uif)
{
  CGFloat ascent  = uif.ascender;            /* positive */
  CGFloat descent = -uif.descender;          /* descender is negative */
  CGSize cell = [@"M" sizeWithAttributes:@{NSFontAttributeName: uif}];
  int cw = (int) ceil (cell.width);
  if (cw < 1) cw = 1;
  int h = (int) ceil (ascent + descent);
  if (h < 1) h = 1;
  font->pixel_size = (int) ceil (uif.pointSize);
  font->height = h;
  font->ascent = (int) ceil (ascent);
  font->descent = (int) ceil (descent);
  font->space_width = cw;
  font->average_width = cw;
  font->min_width = cw;
  font->max_width = cw;
  font->underline_thickness = 1;
  font->underline_position = font->descent / 2;
  font->baseline_offset = 0;
  font->relative_compose = 0;
  font->default_ascent = 0;
  font->vertical_centering = 0;
}

static Lisp_Object
ios_font_one_entity (void)
{
  Lisp_Object entity = font_make_entity ();
  ASET (entity, FONT_TYPE_INDEX, Qios);
  ASET (entity, FONT_FOUNDRY_INDEX, intern ("apple"));
  ASET (entity, FONT_FAMILY_INDEX, intern ("Menlo"));
  ASET (entity, FONT_ADSTYLE_INDEX, Qnil);
  ASET (entity, FONT_REGISTRY_INDEX, intern ("iso10646-1"));
  /* Size 0 marks the font as scalable so open_font uses pixel_size
     from the spec / frame.  */
  ASET (entity, FONT_SIZE_INDEX, make_fixnum (0));
  ASET (entity, FONT_AVGWIDTH_INDEX, make_fixnum (0));
  ASET (entity, FONT_SPACING_INDEX, make_fixnum (FONT_SPACING_MONO));
  /* Use the symbolic Qnormal -> numeric style packing helper.
     There are no FONT_*_NORMAL plain integer constants; weight/slant/
     width style values are encoded in the upper byte of the property
     by font_style_to_value applied to Qnormal.  */
  FONT_SET_STYLE (entity, FONT_WEIGHT_INDEX, Qnormal);
  FONT_SET_STYLE (entity, FONT_SLANT_INDEX, Qnormal);
  FONT_SET_STYLE (entity, FONT_WIDTH_INDEX, Qnormal);
  return entity;
}

static Lisp_Object
ios_font_get_cache (struct frame *f)
{
  struct ios_display_info *dpyinfo = FRAME_DISPLAY_INFO (f);
  return dpyinfo->name_list_element;
}

static Lisp_Object
ios_font_list (struct frame *f, Lisp_Object font_spec)
{
  (void) f; (void) font_spec;
  return list1 (ios_font_one_entity ());
}

static Lisp_Object
ios_font_match (struct frame *f, Lisp_Object font_spec)
{
  (void) f; (void) font_spec;
  return ios_font_one_entity ();
}

static Lisp_Object
ios_font_list_family (struct frame *f)
{
  (void) f;
  return list1 (intern ("Menlo"));
}

static Lisp_Object
ios_font_open (struct frame *f, Lisp_Object font_entity, int pixel_size)
{
  int requested = pixel_size;
  /* Degenerate sizes produce 1px-wide cells that collapse the whole
     frame layout (a 1pt Menlo measures M at width 1, height 2, and
     adjust_frame_size then computes cols == pixels).  Sizes this
     small are never intentional on a 326+ dpi display -- they come
     from size-less specs whose pixel field decodes as a tiny
     integer.  Fall back to the frame's current size.  */
  if (pixel_size < 6)
    {
      /* Log the entity verbatim once per startup so we can name
         the upstream caller without spamming every redisplay
         (face realization re-opens lazily on demand).  */
      static bool logged = false;
      if (!logged)
        {
          logged = true;
          Lisp_Object entity_str
            = Fprin1_to_string (font_entity, Qnil, Qnil);
          ios_launch_log ([NSString stringWithFormat:
            @"ios_font_open: degenerate request size=%d entity=%s",
            requested,
            STRINGP (entity_str) ? SSDATA (entity_str) : "(?)"]);
        }
      if (FRAME_FONT (f))
        pixel_size = FRAME_FONT (f)->pixel_size;
      else
        pixel_size = 14;
      if (pixel_size < 6)
        pixel_size = 14;
    }
  ios_launch_log ([NSString stringWithFormat:
                   @"ios_font_open: requested=%d using=%d",
                   requested, pixel_size]);

  Lisp_Object font_object
    = font_make_object (VECSIZE (struct ios_font_info),
                        font_entity, pixel_size);
  ASET (font_object, FONT_TYPE_INDEX, Qios);

  struct ios_font_info *info
    = (struct ios_font_info *) XFONT_OBJECT (font_object);
  struct font *font = &info->font;
  font->driver = &ios_font_driver;

  UIFont *uif = ios_font_default (pixel_size);
  info->uifont = (__bridge_retained void *) uif;

  ios_font_fill_metrics (font, uif);

  font->props[FONT_NAME_INDEX] = Ffont_xlfd_name (font_object, Qnil, Qt);
  return font_object;
}

static void
ios_font_close (struct font *font)
{
  struct ios_font_info *info = (struct ios_font_info *) font;
  if (info->uifont)
    {
      UIFont *uif = (__bridge_transfer UIFont *) info->uifont;
      (void) uif;
      info->uifont = NULL;
    }
}

static int
ios_font_has_char (Lisp_Object font, int c)
{
  (void) font;
  return (c >= 0 && c <= 0xffff) ? 1 : 0;
}

static unsigned
ios_font_encode_char (struct font *font, int c)
{
  (void) font;
  return (unsigned) c;
}

static void
ios_font_text_extents (struct font *font,
                       const unsigned *code, int nglyphs,
                       struct font_metrics *metrics)
{
  (void) code;
  metrics->lbearing = 0;
  metrics->rbearing = nglyphs * font->space_width;
  metrics->width    = nglyphs * font->space_width;
  metrics->ascent   = font->ascent;
  metrics->descent  = font->descent;
}

#ifdef HAVE_WINDOW_SYSTEM
static int
ios_font_draw (struct glyph_string *s, int from, int to,
               int x, int y, bool with_background)
{
  (void) s; (void) from; (void) to;
  (void) x; (void) y; (void) with_background;
  return 0;
}
#endif

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
#ifdef HAVE_WINDOW_SYSTEM
    .draw            = ios_font_draw,
#endif
  };

void
syms_of_iosfont (void)
{
  /* Qios is DEFSYM'd in iosterm.m; we just register the driver
     here.  Frame-level (per-frame) registration happens later in
     Fx_create_frame.  */
  register_font_driver (&ios_font_driver, NULL);
}

#endif /* HAVE_IOS */
