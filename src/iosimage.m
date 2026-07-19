/* iOS image-loading bridge for GNU Emacs.
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

/* iOS analogue of src/nsimage.m for the HAVE_NATIVE_IMAGE_API
   image-loading path (image.c::native_image_load).  We decode
   through ImageIO so all of the system formats (PNG, JPEG, GIF,
   HEIC, TIFF, BMP, ICO, multi-frame TIFF/GIF) are available without
   pulling in any third-party libraries.

   The loaded image lives behind img->pixmap as a CFRetained
   CGImageRef.  Lifetime: native_image_load CFRetains once
   (CGImageSourceCreateImageAtIndex returns +1), then we transfer
   that retain to img->pixmap; image.c's CLEAR_IMAGE_PIXMAP path
   calls terminal->free_pixmap which CGImageReleases it.  Drawing
   inside iosterm.m / ios.m wraps the same CGImageRef into draw
   commands by CFBridgingRetain'ing it into an ARC strong ref, so
   the command keeps its own +1 -- a redisplay still in flight when
   image.c clears the pixmap does not deref a freed image.  */

#include <config.h>

#ifdef HAVE_IOS

#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <MobileCoreServices/MobileCoreServices.h>

#include "lisp.h"
#include "dispextern.h"
#include "frame.h"
#include "iosterm.h"

/* Symbols passed back through image_can_use_native_api.  These mirror
   what nsimage.m claims on macOS minus the ones with iOS-specific
   restrictions (no .ico support, no PostScript decoder).  */
bool
ios_can_use_native_image_api (Lisp_Object type)
{
  if (EQ (type, Qnative_image)
      || EQ (type, Qpng)
      || EQ (type, Qjpeg)
      || EQ (type, Qgif)
      || EQ (type, Qtiff)
      || EQ (type, Qheic)
      || EQ (type, Qbmp))
    return true;
  return false;
}

/* Decode SPEC_FILE (a file path) or SPEC_DATA (a unibyte string of
   bytes) through ImageIO, pull the INDEXth frame, and stash its
   CGImageRef on img->pixmap.  Returns 1 on success, 0 on failure.
   On failure, add_to_log records the problem with the image spec so
   the user gets a clue via *Messages*.  */
bool
ios_load_image (struct frame *f, struct image *img,
                Lisp_Object spec_file, Lisp_Object spec_data)
{
  (void) f;
  Lisp_Object lisp_index = plist_get (XCDR (img->spec), QCindex);
  size_t index = FIXNATP (lisp_index) ? XFIXNAT (lisp_index) : 0;

  CGImageSourceRef src = NULL;
  if (STRINGP (spec_file))
    {
      NSString *path = [NSString stringWithUTF8String:SSDATA (spec_file)];
      if (path == nil)
        {
          add_to_log ("Image file path is not a valid UTF-8 string");
          return 0;
        }
      NSURL *url = [NSURL fileURLWithPath:path];
      src = CGImageSourceCreateWithURL ((__bridge CFURLRef) url, NULL);
    }
  else if (STRINGP (spec_data))
    {
      NSData *data = [NSData dataWithBytes:SSDATA (spec_data)
                                    length:SBYTES (spec_data)];
      src = CGImageSourceCreateWithData ((__bridge CFDataRef) data, NULL);
    }
  else
    {
      add_to_log ("Image spec lacks both :file and :data");
      return 0;
    }

  if (src == NULL)
    {
      add_to_log ("ImageIO could not open image source: %s", img->spec);
      return 0;
    }

  size_t count = CGImageSourceGetCount (src);
  if (count == 0)
    {
      CFRelease (src);
      add_to_log ("Image source contains zero frames: %s", img->spec);
      return 0;
    }
  if (index >= count)
    {
      CFRelease (src);
      add_to_log ("Image frame index %d out of range (count %d)",
                  make_fixnum (index), make_fixnum (count));
      return 0;
    }

  CGImageRef cg = CGImageSourceCreateImageAtIndex (src, index, NULL);
  CFRelease (src);
  if (cg == NULL)
    {
      add_to_log ("ImageIO frame decode failed: %s", img->spec);
      return 0;
    }

  img->width = (int) CGImageGetWidth (cg);
  img->height = (int) CGImageGetHeight (cg);
  img->pixmap = (void *) cg;       /* transfer +1 retain */
  img->mask = NULL;
  img->lisp_data = Qnil;
  return 1;
}

/* terminal->free_pixmap hook for output_ios frames.  Treated as a
   CGImageRef.  CGImageRelease tolerates NULL.  */
void
ios_free_pixmap (struct frame *f, Emacs_Pixmap pixmap)
{
  (void) f;
  CGImageRelease ((CGImageRef) pixmap);
}

#endif /* HAVE_IOS */
