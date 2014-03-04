//
//  JBLineChartView.m
//  Nudge
//
//  Created by Terry Worona on 9/4/13.
//  Copyright (c) 2013 Jawbone. All rights reserved.
//

#import "JBLineChartView.h"

// Drawing
#import <QuartzCore/QuartzCore.h>

// Enums
typedef NS_ENUM(NSInteger, JBLineChartLineViewState){
	JBLineChartLineViewStateExpanded,
    JBLineChartLineViewStateCollapsed
};

// Numerics (JBLineChartLineView)
CGFloat static const kJBLineChartLineViewEdgePadding = 10.0;
CGFloat static const kJBLineChartLineViewStrokeWidth = 5.0;
CGFloat static const kJBLineChartLineViewMiterLimit = -5.0;
CGFloat static const kJBLineChartLineViewStateAnimationDuration = 0.25f;

// Numerics (JBLineSelectionView)
CGFloat static const kJBLineSelectionViewWidth = 20.0f;

// Numerics (JBLineChartView)
CGFloat static const kJBLineChartViewUndefinedMaxHeight = -1.0f;

// Colors (JBLineChartView)
static UIColor *kJBLineChartViewDefaultLineColor = nil;

@interface CALineLayer : CAShapeLayer

@property (nonatomic, assign) NSInteger tag;

@end

@interface JBLineChartPoint : NSObject

@property (nonatomic, assign) CGPoint position;

@end

@protocol JBLineChartLineViewDelegate;

@interface JBLineChartLineView : UIView

@property (nonatomic, assign) id<JBLineChartLineViewDelegate> delegate;
@property (nonatomic, assign) JBLineChartLineViewState state;
@property (nonatomic, assign) BOOL animated;

// Data
- (void)reloadData;

// Setters
- (void)setState:(JBLineChartLineViewState)state animated:(BOOL)animated callback:(void (^)())callback;
- (void)setState:(JBLineChartLineViewState)state animated:(BOOL)animated;

// Callback helpers
- (void)fireCallback:(void (^)())callback;

// View helpers
- (CALineLayer *)lineLayerForLineIndex:(NSUInteger)lineIndex;

@end

@protocol JBLineChartLineViewDelegate <NSObject>

- (NSArray *)chartDataForLineChartLineView:(JBLineChartLineView*)lineChartLineView;
- (UIColor *)lineChartLineView:(JBLineChartLineView *)lineChartLineView colorForLineAtLineIndex:(NSInteger)lineIndex;
- (CGFloat)lineChartLineView:(JBLineChartLineView *)lineChartLineView widthForLineAtLineIndex:(NSInteger)lineIndex;

@end

@interface JBLineChartView () <JBLineChartLineViewDelegate>

@property (nonatomic, strong) NSArray *chartData;
@property (nonatomic, strong) JBLineChartLineView *lineView;
@property (nonatomic, strong) JBChartSelectionView *selectionView;
@property (nonatomic, assign) CGFloat cachedMaxHeight;
@property (nonatomic, assign) BOOL selectionViewVisible;

// View quick accessors
- (CGFloat)normalizedHeightForRawHeight:(CGFloat)rawHeight;
- (CGFloat)availableHeight;
- (CGFloat)maxHeight;
- (CGFloat)minHeight;
- (NSInteger)dataCount;

// Touch helpers
- (NSArray *)largestLineData; // largest collection of line data
- (NSInteger)indexForPoint:(CGPoint)point;
- (void)touchesEndedOrCancelledWithTouches:(NSSet *)touches;

// Setters
- (void)setSelectionViewVisible:(BOOL)selectionViewVisible animated:(BOOL)animated;

@end

@implementation JBLineChartView

#pragma mark - Alloc/Init

+ (void)initialize
{
	if (self == [JBLineChartView class])
	{
		kJBLineChartViewDefaultLineColor = [UIColor blackColor];
	}
}

- (id)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self)
    {
        self.clipsToBounds = NO;
        _showsSelection = YES;
        _cachedMaxHeight = kJBLineChartViewUndefinedMaxHeight;
    }
    return self;
}

- (id)init
{
    return [self initWithFrame:CGRectZero];
}

#pragma mark - Data

- (void)reloadData
{
    // reset cached max height
    self.cachedMaxHeight = kJBLineChartViewUndefinedMaxHeight;

    /*
     * Subview rectangle calculations
     */
    CGRect mainViewRect = CGRectMake(self.bounds.origin.x, self.bounds.origin.y, self.bounds.size.width, [self availableHeight]);

    /*
     * The data collection holds all position and marker information:
     * constructed via datasource and delegate functions
     */
    dispatch_block_t createChartData = ^{

        CGFloat pointSpace = (self.bounds.size.width - (kJBLineChartLineViewEdgePadding * 2)) / ([self dataCount] - 1); // Space in between points
        CGFloat xOffset = kJBLineChartLineViewEdgePadding;
        CGFloat yOffset = 0;
       
        NSMutableArray *mutableChartData = [NSMutableArray array];
        NSAssert([self.dataSource respondsToSelector:@selector(numberOfLinesInLineChartView:)], @"JBLineChartView // dataSource must implement - (NSInteger)numberOfLinesInLineChartView:(JBLineChartView *)lineChartView");
        for (NSUInteger lineIndex=0; lineIndex<[self.dataSource numberOfLinesInLineChartView:self]; lineIndex++)
        {
            NSAssert([self.dataSource respondsToSelector:@selector(lineChartView:numberOfVerticalValuesAtLineIndex:)], @"JBLineChartView // dataSource must implement - (NSInteger)lineChartView:(JBLineChartView *)lineChartView numberOfVerticalValuesAtLineIndex:(NSInteger)lineIndex");
            NSInteger dataCount = [self.dataSource lineChartView:self numberOfVerticalValuesAtLineIndex:lineIndex];
            NSMutableArray *chartPointData = [NSMutableArray array];
            for (NSUInteger horizontalIndex=0; horizontalIndex<dataCount; horizontalIndex++)
            {                
                NSAssert([self.delegate respondsToSelector:@selector(lineChartView:verticalValueForHorizontalIndex:atLineIndex:)], @"JBLineChartView // delegate must implement - (CGFloat)lineChartView:(JBLineChartView *)lineChartView verticalValueForHorizontalIndex:(NSInteger)horizontalIndex atLineIndex:(NSInteger)lineIndex");
                CGFloat rawHeight =  [self.delegate lineChartView:self verticalValueForHorizontalIndex:horizontalIndex atLineIndex:lineIndex];
                CGFloat normalizedHeight = [self normalizedHeightForRawHeight:rawHeight];
                yOffset = mainViewRect.size.height - normalizedHeight;
                
                JBLineChartPoint *chartPoint = [[JBLineChartPoint alloc] init];
                chartPoint.position = CGPointMake(xOffset, yOffset);
                
                [chartPointData addObject:chartPoint];
                xOffset += pointSpace;
            }
            [mutableChartData addObject:chartPointData];
            xOffset = kJBLineChartLineViewEdgePadding;
        }
        self.chartData = [NSArray arrayWithArray:mutableChartData];
	};

    /*
     * Creates a new line graph view using the previously calculated data model
     */
    dispatch_block_t createLineGraphView = ^{

        // Remove old line and overlay views
        if (self.lineView)
        {
            [self.lineView removeFromSuperview];
            self.lineView = nil;
        }

        // Create new line and overlay subviews
        self.lineView = [[JBLineChartLineView alloc] initWithFrame:CGRectOffset(mainViewRect, 0, self.headerView.frame.size.height + self.headerPadding)];
        self.lineView.delegate = self;
        [self addSubview:self.lineView];
    };

    /*
     * Creates a vertical selection view for touch events
     */
    dispatch_block_t createSelectionView = ^{
        if (self.selectionView)
        {
            [self.selectionView removeFromSuperview];
            self.selectionView = nil;
        }

        self.selectionView = [[JBChartSelectionView alloc] initWithFrame:CGRectMake(0, 0, kJBLineSelectionViewWidth, self.bounds.size.height - self.footerView.frame.size.height)];
        self.selectionView.alpha = 0.0;
        if ([self.dataSource respondsToSelector:@selector(selectionColorForLineChartView:)])
        {
            self.selectionView.bgColor = [self.dataSource selectionColorForLineChartView:self];
        }
        [self insertSubview:self.selectionView belowSubview:self.footerView];
    };

    createChartData();
    createLineGraphView();
    createSelectionView();

    // Reload views
    [self.lineView reloadData];

    // Position header and footer
    self.headerView.frame = CGRectMake(self.bounds.origin.x, self.bounds.origin.y, self.bounds.size.width, self.headerView.frame.size.height);
    self.footerView.frame = CGRectMake(self.bounds.origin.x, self.bounds.size.height - self.footerView.frame.size.height, self.bounds.size.width, self.footerView.frame.size.height);
}

#pragma mark - View Quick Accessors

- (CGFloat)normalizedHeightForRawHeight:(CGFloat)rawHeight
{
    CGFloat minHeight = [self minHeight];
    CGFloat maxHeight = [self maxHeight];

    if ((maxHeight - minHeight) <= 0)
    {
        return 0;
    }

    return ((rawHeight - minHeight) / (maxHeight - minHeight)) * [self availableHeight];
}

- (CGFloat)availableHeight
{
    return self.bounds.size.height - self.headerView.frame.size.height - self.footerView.frame.size.height - self.headerPadding;
}

- (CGFloat)maxHeight
{
    if (self.cachedMaxHeight == kJBLineChartViewUndefinedMaxHeight)
    {
        CGFloat maxHeight = 0;
        NSAssert([self.dataSource respondsToSelector:@selector(numberOfLinesInLineChartView:)], @"JBLineChartView // dataSource must implement - (NSInteger)numberOfLinesInLineChartView:(JBLineChartView *)lineChartView");
        for (NSUInteger lineIndex=0; lineIndex<[self.dataSource numberOfLinesInLineChartView:self]; lineIndex++)
        {
            NSAssert([self.dataSource respondsToSelector:@selector(lineChartView:numberOfVerticalValuesAtLineIndex:)], @"JBLineChartView // dataSource must implement - (NSInteger)lineChartView:(JBLineChartView *)lineChartView numberOfVerticalValuesAtLineIndex:(NSInteger)lineIndex");
            NSInteger dataCount = [self.dataSource lineChartView:self numberOfVerticalValuesAtLineIndex:lineIndex];
            for (NSUInteger horizontalIndex=0; horizontalIndex<dataCount; horizontalIndex++)
            {
                NSAssert([self.delegate respondsToSelector:@selector(lineChartView:verticalValueForHorizontalIndex:atLineIndex:)], @"JBLineChartView // delegate must implement - (CGFloat)lineChartView:(JBLineChartView *)lineChartView verticalValueForHorizontalIndex:(NSInteger)horizontalIndex atLineIndex:(NSInteger)lineIndex");
                CGFloat height = [self.delegate lineChartView:self verticalValueForHorizontalIndex:horizontalIndex atLineIndex:lineIndex];
                if (height > maxHeight)
                {
                    maxHeight = height;
                }
            }
        }
        self.cachedMaxHeight = maxHeight;
    }
    return self.cachedMaxHeight;
}

- (CGFloat)minHeight
{
    return 0;
}

- (NSInteger)dataCount
{
    NSInteger dataCount = 0;
    NSAssert([self.dataSource respondsToSelector:@selector(numberOfLinesInLineChartView:)], @"JBLineChartView // dataSource must implement - (NSInteger)numberOfLinesInLineChartView:(JBLineChartView *)lineChartView");
    for (NSUInteger lineIndex=0; lineIndex<[self.dataSource numberOfLinesInLineChartView:self]; lineIndex++)
    {
        NSAssert([self.dataSource respondsToSelector:@selector(lineChartView:numberOfVerticalValuesAtLineIndex:)], @"JBLineChartView // dataSource must implement - (NSInteger)lineChartView:(JBLineChartView *)lineChartView numberOfVerticalValuesAtLineIndex:(NSInteger)lineIndex");
        NSInteger lineDataCount = [self.dataSource lineChartView:self numberOfVerticalValuesAtLineIndex:lineIndex];
        if (lineDataCount > dataCount)
        {
            dataCount = lineDataCount;
        }
    }
    return dataCount;
}

#pragma mark - JBLineChartLineViewDelegate

- (NSArray *)chartDataForLineChartLineView:(JBLineChartLineView *)lineChartLineView
{
    return self.chartData;
}

- (UIColor *)lineChartLineView:(JBLineChartLineView *)lineChartLineView colorForLineAtLineIndex:(NSInteger)lineIndex
{
    if ([self.dataSource respondsToSelector:@selector(lineChartView:colorForLineAtLineIndex:)])
    {
        return [self.dataSource lineChartView:self colorForLineAtLineIndex:lineIndex];
    }
    return kJBLineChartViewDefaultLineColor;
}

- (CGFloat)lineChartLineView:(JBLineChartLineView *)lineChartLineView widthForLineAtLineIndex:(NSInteger)lineIndex
{
    if ([self.dataSource respondsToSelector:@selector(lineChartView:widthForLineAtLineIndex:)])
    {
        return [self.dataSource lineChartView:self widthForLineAtLineIndex:lineIndex];
    }
    return kJBLineChartLineViewStrokeWidth;
}

#pragma mark - Setters

- (void)setState:(JBChartViewState)state animated:(BOOL)animated callback:(void (^)())callback
{
    [super setState:state animated:animated callback:callback];

    if (state == JBChartViewStateCollapsed)
    {
        [self.lineView setState:JBLineChartLineViewStateCollapsed animated:animated callback:callback];
    }
    else if (state == JBChartViewStateExpanded)
    {
        [self.lineView setState:JBLineChartLineViewStateExpanded animated:animated callback:callback];
    }
}

#pragma mark - Touch Helpers

- (NSArray *)largestLineData
{
    NSArray *largestLineData = nil;
    for (NSArray *lineData in self.chartData)
    {
        if ([lineData count] > [largestLineData count])
        {
            largestLineData = lineData;
        }
    }
    return largestLineData;
}

- (NSInteger)indexForPoint:(CGPoint)point
{
    NSUInteger index = 0;
    CGFloat currentDistance = INT_MAX;
    NSUInteger selectedIndex = -1;
    for (JBLineChartPoint *lineChartPoint in [self largestLineData])
    {
        if ((abs(point.x - lineChartPoint.position.x)) < currentDistance)
        {
            currentDistance = (abs(point.x - lineChartPoint.position.x));
            selectedIndex = index;
        }
        index++;
    }
    return selectedIndex;
}

- (void)touchesEndedOrCancelledWithTouches:(NSSet *)touches
{
    if (!self.showsSelection || self.state == JBChartViewStateCollapsed)
    {
        return;
    }

    [self setSelectionViewVisible:NO animated:YES];

    UITouch *touch = [touches anyObject];
    CGPoint touchPoint = [touch locationInView:self];
    NSInteger index = [self indexForPoint:touchPoint];
    
    if ([self.delegate respondsToSelector:@selector(lineChartView:didUnselectChartAtHorizontalIndex:atLineIndex:)])
    {
        [self.delegate lineChartView:self didUnselectChartAtHorizontalIndex:index atLineIndex:0];
    }
}

#pragma mark - Setters

- (void)setSelectionViewVisible:(BOOL)selectionViewVisible animated:(BOOL)animated
{
    _selectionViewVisible = selectionViewVisible;

    [self bringSubviewToFront:self.selectionView];

    if (animated)
    {
        [UIView animateWithDuration:kJBChartViewDefaultAnimationDuration delay:0.0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
            self.selectionView.alpha = self.selectionViewVisible ? 1.0 : 0.0;
        } completion:nil];
    }
    else
    {
        self.selectionView.alpha = _selectionViewVisible ? 1.0 : 0.0;
    }
}

- (void)setSelectionViewVisible:(BOOL)selectionViewVisible
{
    [self setSelectionViewVisible:selectionViewVisible animated:NO];
}

#pragma mark - Gestures

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
    if (!self.showsSelection || self.state == JBChartViewStateCollapsed)
    {
        return;
    }

    UITouch *touch = [touches anyObject];
    CGPoint touchPoint = [touch locationInView:self];

    if ([self.delegate respondsToSelector:@selector(lineChartView:didSelectChartAtHorizontalIndex:atLineIndex:)])
    {
        [self.delegate lineChartView:self didSelectChartAtHorizontalIndex:[self indexForPoint:touchPoint] atLineIndex:0];
    }
    
    CGFloat xOffset = fmin(self.bounds.size.width - self.selectionView.frame.size.width, fmax(0, touchPoint.x - (ceil(self.selectionView.frame.size.width * 0.5))));
    self.selectionView.frame = CGRectMake(xOffset, self.selectionView.frame.origin.y, self.selectionView.frame.size.width, self.selectionView.frame.size.height);
    [self setSelectionViewVisible:YES animated:YES];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
    if (!self.showsSelection || self.state == JBChartViewStateCollapsed)
    {
        return;
    }

    UITouch *touch = [touches anyObject];
    CGPoint touchPoint = [touch locationInView:self];
   
    if ([self.delegate respondsToSelector:@selector(lineChartView:didSelectChartAtHorizontalIndex:atLineIndex:)])
    {
        [self.delegate lineChartView:self didSelectChartAtHorizontalIndex:[self indexForPoint:touchPoint] atLineIndex:0];
    }

    CGFloat xOffset = fmin(self.bounds.size.width - self.selectionView.frame.size.width, fmax(0, touchPoint.x - (ceil(self.selectionView.frame.size.width * 0.5))));
    self.selectionView.frame = CGRectMake(xOffset, self.selectionView.frame.origin.y, self.selectionView.frame.size.width, self.selectionView.frame.size.height);
    [self setSelectionViewVisible:YES animated:YES];
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
    [self touchesEndedOrCancelledWithTouches:touches];
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event
{
    [self touchesEndedOrCancelledWithTouches:touches];
}

@end

@implementation JBLineChartLineView

#pragma mark - Alloc/Init

- (id)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self)
    {
        self.clipsToBounds = NO;
        self.backgroundColor = [UIColor clearColor];
    }
    return self;
}

#pragma mark - Memory Management

- (void)dealloc
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
}

#pragma mark - Drawing

- (void)drawRect:(CGRect)rect
{
    [super drawRect:rect];

    CGContextRef context = UIGraphicsGetCurrentContext();

    NSArray *chartData = [self.delegate chartDataForLineChartLineView:self];
    
    NSUInteger lineIndex = 0;
    for (NSArray *lineData in chartData)
    {
        UIBezierPath *flatPath = [UIBezierPath bezierPath];
        flatPath.miterLimit = kJBLineChartLineViewMiterLimit;
        
        UIBezierPath *dynamicPath = [UIBezierPath bezierPath];
        dynamicPath.miterLimit = kJBLineChartLineViewMiterLimit;
        
        NSInteger index = 0;
        for (JBLineChartPoint *lineChartPoint in [lineData sortedArrayUsingSelector:@selector(compare:)])
        {
            if (index == 0)
            {
                [dynamicPath moveToPoint:CGPointMake(lineChartPoint.position.x, fmin(self.bounds.size.height - kJBLineChartLineViewEdgePadding, fmax(kJBLineChartLineViewEdgePadding, lineChartPoint.position.y)))];
                [flatPath moveToPoint:CGPointMake(lineChartPoint.position.x, ceil(self.bounds.size.height * 0.5))];
            }
            else
            {
                [dynamicPath addLineToPoint:CGPointMake(lineChartPoint.position.x, fmin(self.bounds.size.height - kJBLineChartLineViewEdgePadding, fmax(kJBLineChartLineViewEdgePadding, lineChartPoint.position.y)))];
                [flatPath addLineToPoint:CGPointMake(lineChartPoint.position.x, ceil(self.bounds.size.height * 0.5))];
            }
            
            index++;
        }
        
        CALineLayer *shapeLayer = [self lineLayerForLineIndex:lineIndex];
        if (shapeLayer == nil)
        {
            shapeLayer = [CALineLayer layer];
            shapeLayer.tag = lineIndex;
        }
        
        if (self.animated)
        {
            shapeLayer.strokeColor = [self.delegate lineChartLineView:self colorForLineAtLineIndex:lineIndex].CGColor;
            shapeLayer.lineWidth = [self.delegate lineChartLineView:self widthForLineAtLineIndex:lineIndex];
            shapeLayer.path = (self.state == JBLineChartLineViewStateCollapsed) ? dynamicPath.CGPath : flatPath.CGPath;
            shapeLayer.frame = self.bounds;
            
            CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"path"];
            [anim setRemovedOnCompletion:NO];
            anim.toValue = self.state == JBLineChartLineViewStateCollapsed ? (id)flatPath.CGPath : (id)dynamicPath.CGPath;
            anim.duration = kJBLineChartLineViewStateAnimationDuration;
            anim.removedOnCompletion = NO;
            anim.fillMode = kCAFillModeForwards;
            anim.autoreverses = NO;
            anim.repeatCount = 0;
            [shapeLayer addAnimation:anim forKey:@"path"];
            [self.layer addSublayer:shapeLayer];
        }
        else
        {
            CGContextSaveGState(context);
            {
                CGContextSetLineWidth(context, [self.delegate lineChartLineView:self widthForLineAtLineIndex:lineIndex]);
                CGContextSetStrokeColorWithColor(context, [self.delegate lineChartLineView:self colorForLineAtLineIndex:lineIndex].CGColor);
                CGContextSetLineCap(context, kCGLineCapRound);
                CGContextSetLineJoin(context, kCGLineJoinRound);
                CGContextBeginPath(context);
                CGContextAddPath(context, self.state == JBLineChartLineViewStateCollapsed ? flatPath.CGPath : dynamicPath.CGPath);
                CGContextDrawPath(context, kCGPathStroke);
            }
            CGContextRestoreGState(context);
        }
        
        lineIndex++;
    }
    
    self.animated = NO;
}

#pragma mark - Data

- (void)reloadData
{
    // Drawing is all done with CG (no subviews here)
    [self setNeedsDisplay];
}

#pragma mark - Setters

- (void)setState:(JBLineChartLineViewState)state animated:(BOOL)animated callback:(void (^)())callback
{
    if (_state == state)
    {
        return;
    }

    dispatch_block_t callbackCopy = [callback copy];

    _state = state;
    self.animated = animated;
    [self setNeedsDisplay];

    if (animated)
    {
        [self performSelector:@selector(fireCallback:) withObject:callback afterDelay:kJBLineChartLineViewStateAnimationDuration];
    }
    else
    {
        if (callbackCopy)
        {
            callbackCopy();
        }
    }
}

- (void)setState:(JBLineChartLineViewState)state animated:(BOOL)animated
{
    [self setState:state animated:animated callback:nil];
}

#pragma mark - Callback Helpers

- (void)fireCallback:(void (^)())callback
{
    dispatch_block_t callbackCopy = [callback copy];

    if (callbackCopy != nil)
    {
        callbackCopy();
    }
}

- (CALineLayer *)lineLayerForLineIndex:(NSUInteger)lineIndex
{
    for (CALayer *layer in [self.layer sublayers])
    {
        if ([layer isKindOfClass:[CALineLayer class]])
        {
            if (((CALineLayer *)layer).tag == lineIndex)
            {
                return (CALineLayer *)layer;
            }
        }
    }
    return nil;
}

@end

@implementation JBLineChartPoint

#pragma mark - Alloc/Init

- (id)init
{
    self = [super init];
    if (self)
    {
        _position = CGPointZero;
    }
    return self;
}

#pragma mark - Compare

- (NSComparisonResult)compare:(JBLineChartPoint *)otherObject
{
    return self.position.x > otherObject.position.x;
}

@end

@implementation CALineLayer

#pragma mark - Alloc/Init

- (id)init
{
    self = [super init];
    if (self)
    {
        self.zPosition = 0.0f;
        self.lineCap = kCALineCapRound;
        self.lineJoin = kCALineJoinRound;
        self.fillColor = [UIColor clearColor].CGColor;
    }
    return self;
}

@end
