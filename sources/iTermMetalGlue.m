//
//  iTermMetalGlue.m
//  iTerm2SharedARC
//
//  Created by George Nachman on 10/8/17.
//

#import "iTermMetalGlue.h"

#import "DebugLogging.h"
#import "iTermColorMap.h"
#import "iTermController.h"
#import "iTermSelection.h"
#import "iTermTextDrawingHelper.h"
#import "NSColor+iTerm.h"
#import "PTYFontInfo.h"
#import "PTYTextView.h"
#import "VT100Screen.h"

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    unsigned int isMatch : 1;
    unsigned int inUnderlinedRange : 1;
    unsigned int selected : 1;
    unsigned int foregroundColor : 8;
    unsigned int fgGreen : 8;
    unsigned int fgBlue  : 8;
    unsigned int bold : 1;
    unsigned int faint : 1;
    CGFloat backgroundColor[4];
} iTermTextColorKey;

typedef struct {
    int bgColor;
    int bgGreen;
    int bgBlue;
    ColorMode bgColorMode;
    BOOL selected;
    BOOL isMatch;
} iTermBackgroundColorKey;

static vector_float4 VectorForColor(NSColor *color) {
    return (vector_float4) { color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent };
}

static NSColor *ColorForVector(vector_float4 v) {
    return [NSColor colorWithRed:v.x green:v.y blue:v.z alpha:v.w];
}

@implementation iTermMetalGlue {
    BOOL _skip;
    BOOL _havePreviousCharacterAttributes;
    screen_char_t _previousCharacterAttributes;
    vector_float4 _lastUnprocessedColor;
    BOOL _havePreviousForegroundColor;
    vector_float4 _previousForegroundColor;
    NSMutableArray<NSData *> *_lines;
    NSMutableArray<NSIndexSet *> *_selectedIndexes;
    NSMutableDictionary<NSNumber *, NSData *> *_matches;
    iTermColorMap *_colorMap;
    PTYFontInfo *_asciiFont;
    PTYFontInfo *_nonAsciiFont;
    BOOL _useBoldFont;
    BOOL _useItalicFont;
    BOOL _useNonAsciiFont;
    BOOL _reverseVideo;
    BOOL _useBrightBold;
    BOOL _isFrontTextView;
    vector_float4 _unfocusedSelectionColor;
    CGFloat _transparencyAlpha;
    BOOL _transparencyAffectsOnlyDefaultBackgroundColor;
    iTermMetalCursorInfo *_cursorInfo;
}

#pragma mark - iTermMetalDriverDataSource

- (void)metalDriverWillBeginDrawingFrame {
    if (self.textView.drawingHelper.delegate == nil) {
        _skip = YES;
        return;
    }
    _skip = NO;

    _havePreviousCharacterAttributes = NO;
    _isFrontTextView = (self.textView == [[iTermController sharedInstance] frontTextView]);
    _unfocusedSelectionColor = VectorForColor([[_colorMap colorForKey:kColorMapSelection] colorDimmedBy:2.0/3.0
                                                                                       towardsGrayLevel:0.5]);
    _transparencyAlpha = self.textView.transparencyAlpha;
    _transparencyAffectsOnlyDefaultBackgroundColor = self.textView.drawingHelper.transparencyAffectsOnlyDefaultBackgroundColor;

    // Copy lines from model. Always use these for consistency. I should also copy the color map
    // and any other data dependencies.
    _lines = [NSMutableArray array];
    _selectedIndexes = [NSMutableArray array];
    _matches = [NSMutableDictionary dictionary];
    VT100GridCoordRange coordRange = [self.textView.drawingHelper coordRangeForRect:self.textView.enclosingScrollView.documentVisibleRect];
    const int width = coordRange.end.x - coordRange.start.x;
    for (int i = coordRange.start.y; i < coordRange.end.y; i++) {
        screen_char_t *line = [self.screen getLineAtIndex:i];
        [_lines addObject:[NSData dataWithBytes:line length:sizeof(screen_char_t) * width]];
        [_selectedIndexes addObject:[self.textView.selection selectedIndexesOnLine:i]];
        NSData *findMatches = [self.textView.drawingHelper.delegate drawingHelperMatchesOnLine:i];
        if (findMatches) {
            _matches[@(i - coordRange.start.y)] = findMatches;
        }
    }

    _colorMap = [self.textView.colorMap copy];
    _asciiFont = self.textView.primaryFont;
    _nonAsciiFont = self.textView.secondaryFont;
    _useBoldFont = self.textView.useBoldFont;
    _useItalicFont = self.textView.useItalicFont;
    _useNonAsciiFont = self.textView.useNonAsciiFont;
    _reverseVideo = self.textView.dataSource.terminal.reverseVideo;
    _useBrightBold = self.textView.useBrightBold;

    _cursorInfo = [[iTermMetalCursorInfo alloc] init];
#warning TODO: blinking cursor
    if (_textView.cursorVisible && coordRange.end.y >= _textView.dataSource.numberOfScrollbackLines) {
        const int offset = coordRange.start.y - _textView.dataSource.numberOfScrollbackLines;
        _cursorInfo.cursorVisible = YES;
        _cursorInfo.type = _textView.drawingHelper.cursorType;
        _cursorInfo.coord = VT100GridCoordMake(_textView.dataSource.cursorX - 1,
                                               _textView.dataSource.cursorY - 1 - offset);
#warning handle frame cursor, text color, smart cursor color, and other fancy cursors of various kinds
        _cursorInfo.cursorColor = [self backgroundColorForCursor];
    } else {
        _cursorInfo.cursorVisible = NO;
    }
}

- (nullable iTermMetalCursorInfo *)metalDriverCursorInfo {
    return _cursorInfo;
}

- (void)metalGetGlyphKeys:(iTermMetalGlyphKey *)glyphKeys
               attributes:(iTermMetalGlyphAttributes *)attributes
               background:(vector_float4 *)background
                      row:(int)row
                    width:(int)width {
    screen_char_t *line = (screen_char_t *)_lines[row].bytes;
    NSIndexSet *selectedIndexes = _selectedIndexes[row];
    NSData *findMatches = _matches[@(row)];
    iTermTextColorKey keys[2];
    iTermTextColorKey *currentColorKey = &keys[0];
    iTermTextColorKey *previousColorKey = &keys[1];
    iTermBackgroundColorKey lastBackgroundKey;

    for (int x = 0; x < width; x++) {
        BOOL selected = [selectedIndexes containsIndex:x];
        BOOL findMatch = NO;
        if (findMatches && !selected) {
            findMatch = CheckFindMatchAtIndex(findMatches, x);
        }

        // Background colors
        iTermBackgroundColorKey backgroundKey = {
            .bgColor = line[x].backgroundColor,
            .bgGreen = line[x].bgGreen,
            .bgBlue = line[x].bgBlue,
            .bgColorMode = line[x].backgroundColorMode,
            .selected = selected,
            .isMatch = findMatch,
        };
        if (x > 1 &&
            backgroundKey.bgColor == lastBackgroundKey.bgColor &&
            backgroundKey.bgGreen == lastBackgroundKey.bgGreen &&
            backgroundKey.bgBlue == lastBackgroundKey.bgBlue &&
            backgroundKey.bgColorMode == lastBackgroundKey.bgColorMode &&
            backgroundKey.selected == lastBackgroundKey.selected &&
            backgroundKey.isMatch == lastBackgroundKey.isMatch) {
            background[x] = background[x - 1];
        } else {
            vector_float4 unprocessed = [self unprocessedColorForBackgroundColorKey:&backgroundKey];
            // The unprocessed color is needed for minimum contrast computation for text color.
            background[x] = [_colorMap fastProcessedBackgroundColorForBackgroundColor:unprocessed];
        }
        lastBackgroundKey = backgroundKey;

        // Foreground colors
        // Build up a compact key describing all the inputs to a text color
        currentColorKey->isMatch = findMatch;
        currentColorKey->inUnderlinedRange = NO;  // TODO
        currentColorKey->selected = selected;
        currentColorKey->foregroundColor = line[x].foregroundColor;
        currentColorKey->fgGreen = line[x].fgGreen;
        currentColorKey->fgBlue = line[x].fgBlue;
        currentColorKey->bold = line[x].bold;
        currentColorKey->faint = line[x].faint;
        currentColorKey->backgroundColor[0] = 0;  // TODO
        currentColorKey->backgroundColor[1] = 0;  // TODO
        currentColorKey->backgroundColor[2] = 0;  // TODO
        if (x > 0 &&
            currentColorKey->isMatch == previousColorKey->isMatch &&
            currentColorKey->inUnderlinedRange == previousColorKey->inUnderlinedRange &&
            currentColorKey->selected == previousColorKey->selected &&
            currentColorKey->foregroundColor == previousColorKey->foregroundColor &&
            currentColorKey->fgGreen == previousColorKey->fgGreen &&
            currentColorKey->fgBlue == previousColorKey->fgBlue &&
            currentColorKey->bold == previousColorKey->bold &&
            currentColorKey->faint == previousColorKey->faint &&
            currentColorKey->backgroundColor[0] == previousColorKey->backgroundColor[0] &&
            currentColorKey->backgroundColor[1] == previousColorKey->backgroundColor[1] &&
            currentColorKey->backgroundColor[2] == previousColorKey->backgroundColor[2]) {
            memcpy(attributes[x].foregroundColor,
                   attributes[x - 1].foregroundColor,
                   sizeof(CGFloat) * 4);
        } else {
            vector_float4 textColor = [self textColorForCharacter:&line[x]
                                                             line:row
                                                  backgroundColor:background[x]
                                                         selected:selected
                                                        findMatch:findMatch
                                                inUnderlinedRange:NO  // TODO
                                                            index:x];
            attributes[x].foregroundColor[0] = textColor.x;
            attributes[x].foregroundColor[1] = textColor.y;
            attributes[x].foregroundColor[2] = textColor.z;
            attributes[x].foregroundColor[3] = textColor.w;
        }

        // Swap current and previous
        iTermTextColorKey *temp = currentColorKey;
        currentColorKey = previousColorKey;
        previousColorKey = temp;

        // Also need to take into account which font will be used (bold, italic, nonascii, etc.) plus
        // box drawing and images. If I want to support subpixel rendering then background color has
        // to be a factor also.
        glyphKeys[x].code = line[x].code;
        glyphKeys[x].isComplex = line[x].complexChar;
        glyphKeys[x].image = line[x].image;
        glyphKeys[x].boxDrawing = NO;
    }

    // Tweak the text color for the cell that has a box cursor.
    if (_cursorInfo.cursorVisible &&
        _cursorInfo.type == CURSOR_BOX &&
        row == _cursorInfo.coord.y) {
        vector_float4 cursorTextColor;
        if (_reverseVideo) {
            cursorTextColor = VectorForColor([_colorMap colorForKey:kColorMapBackground]);
        } else {
            cursorTextColor = [self colorForCode:ALTSEM_CURSOR
                                           green:0
                                            blue:0
                                       colorMode:ColorModeAlternate
                                            bold:NO
                                           faint:NO
                                    isBackground:NO];
        }
        attributes[_cursorInfo.coord.x].foregroundColor[0] = cursorTextColor.x;
        attributes[_cursorInfo.coord.x].foregroundColor[1] = cursorTextColor.y;
        attributes[_cursorInfo.coord.x].foregroundColor[2] = cursorTextColor.z;
        attributes[_cursorInfo.coord.x].foregroundColor[3] = cursorTextColor.w;
    }
}

- (vector_float4)selectionColorForCurrentFocus {
    if (_isFrontTextView) {
        return VectorForColor([_colorMap processedBackgroundColorForBackgroundColor:[_colorMap colorForKey:kColorMapSelection]]);
    } else {
        return _unfocusedSelectionColor;
    }
}

- (vector_float4)unprocessedColorForBackgroundColorKey:(iTermBackgroundColorKey *)colorKey {
    vector_float4 color = { 0, 0, 0, 0 };
    CGFloat alpha = _transparencyAlpha;
    if (colorKey->selected) {
        color = [self selectionColorForCurrentFocus];
        if (_transparencyAffectsOnlyDefaultBackgroundColor) {
            alpha = 1;
        }
    } else if (colorKey->isMatch) {
        color = (vector_float4){ 1, 1, 0, 1 };
    } else {
        const BOOL defaultBackground = (colorKey->bgColor == ALTSEM_DEFAULT &&
                                        colorKey->bgColorMode == ColorModeAlternate);
        // When set in preferences, applies alpha only to the defaultBackground
        // color, useful for keeping Powerline segments opacity(background)
        // consistent with their seperator glyphs opacity(foreground).
        if (_transparencyAffectsOnlyDefaultBackgroundColor && !defaultBackground) {
            alpha = 1;
        }
        if (_reverseVideo && defaultBackground) {
            // Reverse video is only applied to default background-
            // color chars.
            color = [self colorForCode:ALTSEM_DEFAULT
                                 green:0
                                  blue:0
                             colorMode:ColorModeAlternate
                                  bold:NO
                                 faint:NO
                          isBackground:NO];
        } else {
            // Use the regular background color.
            color = [self colorForCode:colorKey->bgColor
                                 green:colorKey->bgGreen
                                  blue:colorKey->bgBlue
                             colorMode:colorKey->bgColorMode
                                  bold:NO
                                 faint:NO
                          isBackground:YES];
        }

//        if (defaultBackground && _hasBackgroundImage) {
//            alpha = 1 - _blend;
//        }
    }
    color.w = alpha;
    return color;
}

#warning Remember to add support for blinking text.

- (vector_float4)colorForCode:(int)theIndex
                        green:(int)green
                         blue:(int)blue
                    colorMode:(ColorMode)theMode
                         bold:(BOOL)isBold
                        faint:(BOOL)isFaint
                 isBackground:(BOOL)isBackground {
    iTermColorMapKey key = [self colorMapKeyForCode:theIndex
                                              green:green
                                               blue:blue
                                          colorMode:theMode
                                               bold:isBold
                                       isBackground:isBackground];
    if (isBackground) {
        return VectorForColor([_colorMap colorForKey:key]);
    } else {
        vector_float4 color = VectorForColor([_colorMap colorForKey:key]);
        if (isFaint) {
            color.w = 0.5;
        }
        return color;
    }
}

- (iTermColorMapKey)colorMapKeyForCode:(int)theIndex
                                 green:(int)green
                                  blue:(int)blue
                             colorMode:(ColorMode)theMode
                                  bold:(BOOL)isBold
                          isBackground:(BOOL)isBackground {
    BOOL isBackgroundForDefault = isBackground;
    switch (theMode) {
        case ColorModeAlternate:
            switch (theIndex) {
                case ALTSEM_SELECTED:
                    if (isBackground) {
                        return kColorMapSelection;
                    } else {
                        return kColorMapSelectedText;
                    }
                case ALTSEM_CURSOR:
                    if (isBackground) {
                        return kColorMapCursor;
                    } else {
                        return kColorMapCursorText;
                    }
                case ALTSEM_REVERSED_DEFAULT:
                    isBackgroundForDefault = !isBackgroundForDefault;
                    // Fall through.
                case ALTSEM_DEFAULT:
                    if (isBackgroundForDefault) {
                        return kColorMapBackground;
                    } else {
                        if (isBold && _useBrightBold) {
                            return kColorMapBold;
                        } else {
                            return kColorMapForeground;
                        }
                    }
            }
            break;
        case ColorMode24bit:
            return [iTermColorMap keyFor8bitRed:theIndex green:green blue:blue];
        case ColorModeNormal:
            // Render bold text as bright. The spec (ECMA-48) describes the intense
            // display setting (esc[1m) as "bold or bright". We make it a
            // preference.
            if (isBold &&
                _useBrightBold &&
                (theIndex < 8) &&
                !isBackground) { // Only colors 0-7 can be made "bright".
                theIndex |= 8;  // set "bright" bit.
            }
            return kColorMap8bitBase + (theIndex & 0xff);

        case ColorModeInvalid:
            return kColorMapInvalid;
    }
    NSAssert(ok, @"Bogus color mode %d", (int)theMode);
    return kColorMapInvalid;
}

- (NSImage *)metalImageForCharacterAtCoord:(VT100GridCoord)coord
                                      size:(CGSize)size
                                     scale:(CGFloat)scale {
    if (_skip) {
        return nil;
    }
    
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL,
                                             size.width,
                                             size.height,
                                             8,
                                             size.width * 4,
                                             colorSpace,
                                             kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(colorSpace);

    CGContextSetRGBFillColor(ctx, 0, 0, 0, 0);
    CGContextFillRect(ctx, CGRectMake(0, 0, size.width, size.height));

    screen_char_t *line = (screen_char_t *)_lines[coord.y].bytes;
    screen_char_t *sct = line + coord.x;
    BOOL fakeBold = NO;
    BOOL fakeItalic = NO;
    PTYFontInfo *fontInfo = [PTYFontInfo fontForAsciiCharacter:(!sct->complexChar && (sct->code < 128))
                                                     asciiFont:_asciiFont
                                                  nonAsciiFont:_nonAsciiFont
                                                   useBoldFont:_useBoldFont
                                                 useItalicFont:_useItalicFont
                                              usesNonAsciiFont:_useNonAsciiFont
                                                    renderBold:&fakeBold
                                                  renderItalic:&fakeItalic];
    NSFont *font = fontInfo.font;
    assert(font);
    [self drawString:ScreenCharToStr(sct)
                font:font
                size:size
      baselineOffset:fontInfo.baselineOffset
               scale:scale
             context:ctx];

    CGImageRef imageRef = CGBitmapContextCreateImage(ctx);

    return [[NSImage alloc] initWithCGImage:imageRef size:size];
}

#pragma mark - Letter Drawing

- (void)drawString:(NSString *)string
              font:(NSFont *)font
              size:(CGSize)size
    baselineOffset:(CGFloat)baselineOffset
             scale:(CGFloat)scale
           context:(CGContextRef)ctx {
    DLog(@"Draw %@ of size %@", string, NSStringFromSize(size));
    if (string.length == 0) {
        return;
    }
    CGGlyph glyphs[string.length];
    const NSUInteger numCodes = string.length;
    unichar characters[numCodes];
    [string getCharacters:characters];
    BOOL ok = CTFontGetGlyphsForCharacters((CTFontRef)font,
                                           characters,
                                           glyphs,
                                           numCodes);
    if (!ok) {
        // TODO: fall back and use core text
//        assert(NO);
        return;
    }

    // TODO: fake italic, fake bold, optional anti-aliasing, thin strokes, faint
    const BOOL antiAlias = YES;
    CGContextSetShouldAntialias(ctx, antiAlias);

    size_t length = numCodes;

    // TODO: This is slow. Avoid doing it.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CGContextSelectFont(ctx,
                        [[font fontName] UTF8String],
                        [font pointSize],
                        kCGEncodingMacRoman);
#pragma clang diagnostic pop

    // TODO: could use extended srgb on macOS 10.12+
    CGContextSetFillColorSpace(ctx, CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
    const CGFloat components[4] = { 1.0, 1.0, 1.0, 1.0 };
    CGContextSetFillColor(ctx, components);
    double y = -baselineOffset * scale;
    // Flip vertically and translate to (x, y).
    CGContextSetTextMatrix(ctx, CGAffineTransformMake(scale,  0.0,
                                                      0, scale,
                                                      0, y));

    CGPoint points[length];
    for (int i = 0; i < length; i++) {
        points[i].x = 0;
        points[i].y = 0;
    }
    CGContextShowGlyphsAtPositions(ctx, glyphs, points, length);
}

#pragma mark - Color

- (vector_float4)textColorForCharacter:(screen_char_t *)c
                                  line:(int)line
                       backgroundColor:(vector_float4)backgroundColor
                              selected:(BOOL)selected
                             findMatch:(BOOL)findMatch
                     inUnderlinedRange:(BOOL)inUnderlinedRange
                                 index:(int)index {
    vector_float4 rawColor = { 0, 0, 0, 0 };
    BOOL isMatch = NO;
    iTermColorMap *colorMap = _colorMap;
    const BOOL needsProcessing = (colorMap.minimumContrast > 0.001 ||
                                  colorMap.dimmingAmount > 0.001 ||
                                  colorMap.mutingAmount > 0.001 ||
                                  c->faint);  // faint implies alpha<1 and is faster than getting the alpha component


    if (isMatch) {
        // Black-on-yellow search result.
        rawColor = (vector_float4){ 0, 0, 0, 1 };
        _havePreviousCharacterAttributes = NO;
    } else if (inUnderlinedRange) {
        // Blue link text.
        rawColor = VectorForColor([_colorMap colorForKey:kColorMapLink]);
        _havePreviousCharacterAttributes = NO;
    } else if (selected) {
        // Selected text.
        rawColor = VectorForColor([colorMap colorForKey:kColorMapSelectedText]);
        _havePreviousCharacterAttributes = NO;
    } else if (_reverseVideo &&
               ((c->foregroundColor == ALTSEM_DEFAULT && c->foregroundColorMode == ColorModeAlternate) ||
                (c->foregroundColor == ALTSEM_CURSOR && c->foregroundColorMode == ColorModeAlternate))) {
           // Reverse video is on. Either is cursor or has default foreground color. Use
           // background color.
           rawColor = VectorForColor([colorMap colorForKey:kColorMapBackground]);
           _havePreviousCharacterAttributes = NO;
    } else if (!_havePreviousCharacterAttributes ||
               c->foregroundColor != _previousCharacterAttributes.foregroundColor ||
               c->fgGreen != _previousCharacterAttributes.fgGreen ||
               c->fgBlue != _previousCharacterAttributes.fgBlue ||
               c->foregroundColorMode != _previousCharacterAttributes.foregroundColorMode ||
               c->bold != _previousCharacterAttributes.bold ||
               c->faint != _previousCharacterAttributes.faint ||
               !_havePreviousForegroundColor) {
        // "Normal" case for uncached text color. Recompute the unprocessed color from the character.
        _previousCharacterAttributes = *c;
        _havePreviousCharacterAttributes = YES;
        rawColor = [self colorForCode:c->foregroundColor
                                green:c->fgGreen
                                 blue:c->fgBlue
                            colorMode:c->foregroundColorMode
                                 bold:c->bold
                                faint:c->faint
                         isBackground:NO];
    } else {
        // Foreground attributes are just like the last character. There is a cached foreground color.
        if (needsProcessing) {
            // Process the text color for the current background color, which has changed since
            // the last cell.
            rawColor = _lastUnprocessedColor;
        } else {
            // Text color is unchanged. Either it's independent of the background color or the
            // background color has not changed.
            return _previousForegroundColor;
        }
    }

    _lastUnprocessedColor = rawColor;

    vector_float4 result;
    if (needsProcessing) {
        result = VectorForColor([_colorMap processedTextColorForTextColor:ColorForVector(rawColor)
                                                      overBackgroundColor:ColorForVector(backgroundColor)]);
    } else {
        result = rawColor;
    }
    _previousForegroundColor = result;
    _havePreviousForegroundColor = YES;
    return result;
}

- (NSColor *)backgroundColorForCursor {
    NSColor *color;
    if (_reverseVideo) {
        color = [[_colorMap colorForKey:kColorMapCursorText] colorWithAlphaComponent:1.0];
    } else {
        color = [[_colorMap colorForKey:kColorMapCursor] colorWithAlphaComponent:1.0];
    }
    return [_colorMap colorByDimmingTextColor:color];
}

#warning TODO: Lots of code was copied from PTYTextView. Make it shared.


@end

NS_ASSUME_NONNULL_END
