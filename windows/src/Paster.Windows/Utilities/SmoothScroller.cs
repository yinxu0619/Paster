using System.Diagnostics;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Paster.Windows.Services;

namespace Paster.Windows.Utilities;

/// <summary>
/// Wheel and programmatic scrolling driven by one accumulated target offset plus per-frame easing.
///
/// The obvious implementation - <c>ChangeView(offset - delta, disableAnimation: false)</c> once per
/// wheel event - is what made scrolling feel stiff. Each notch reads <c>HorizontalOffset</c> while
/// the previous notch's canned animation is still running, so a burst of notches keeps re-basing on
/// a stale offset: six notches of 120px travelled ~480px instead of 720px, in six visibly separate
/// jerks.
///
/// Here a notch only moves <see cref="_target"/>. A <c>CompositionTarget.Rendering</c> tick eases
/// the real offset toward it with a framerate-independent exponential, so consecutive notches blend
/// into a single continuous glide and the tail decelerates into a coast instead of stopping dead.
/// The same path serves scroll-into-view, which is what keeps a programmatic scroll and an in-flight
/// wheel glide from fighting: they share one target rather than issuing competing ChangeView calls.
/// </summary>
public sealed class SmoothScroller
{
    /// <summary>Seconds for the remaining distance to decay by 1/e. Tuned against the macOS panel.</summary>
    private const double TimeConstantSeconds = 0.105;
    private const double SettleThreshold = 0.4;
    private const double MaxFrameSeconds = 0.05;

    private readonly ScrollViewer _scrollViewer;
    private bool _running;
    private bool _horizontal;
    private double _target;
    private double _current;
    private long _lastTimestamp;

    public SmoothScroller(ScrollViewer scrollViewer) => _scrollViewer = scrollViewer;

    public bool CanScroll(bool horizontal) => MaxOffset(horizontal) > SettleThreshold;

    /// <summary>Adds to the accumulated target; repeated calls compose instead of restarting.</summary>
    public void Nudge(double delta, bool horizontal)
    {
        var origin = _running && _horizontal == horizontal ? _target : CurrentOffset(horizontal);
        Retarget(origin + delta, horizontal);
    }

    /// <summary>Eases to an absolute offset, cancelling any wheel glide on the other axis.</summary>
    public void GlideTo(double offset, bool horizontal) => Retarget(offset, horizontal);

    public void Stop()
    {
        if (!_running)
        {
            return;
        }

        _running = false;
        CompositionTarget.Rendering -= OnRendering;
    }

    private void Retarget(double offset, bool horizontal)
    {
        if (!_running || _horizontal != horizontal)
        {
            // Re-base on the live offset so a scrollbar drag or a layout change is not undone.
            Stop();
            _horizontal = horizontal;
            _current = CurrentOffset(horizontal);
        }

        _target = Math.Clamp(offset, 0, MaxOffset(horizontal));
        if (Math.Abs(_target - _current) < SettleThreshold)
        {
            Stop();
            return;
        }

        if (!_running)
        {
            _running = true;
            _lastTimestamp = Stopwatch.GetTimestamp();
            CompositionTarget.Rendering += OnRendering;
        }
    }

    private void OnRendering(object? sender, object args)
    {
        try
        {
            var now = Stopwatch.GetTimestamp();
            var elapsed = Math.Clamp((now - _lastTimestamp) / (double)Stopwatch.Frequency, 0.0005, MaxFrameSeconds);
            _lastTimestamp = now;

            // Re-clamp every frame: virtualisation changes the extent as items realise.
            _target = Math.Clamp(_target, 0, MaxOffset(_horizontal));
            _current += (_target - _current) * (1 - Math.Exp(-elapsed / TimeConstantSeconds));

            if (Math.Abs(_target - _current) < SettleThreshold)
            {
                _current = _target;
                Apply();
                Stop();
                return;
            }

            Apply();
        }
        catch (Exception ex)
        {
            AppLog.Error("Smooth scroll tick failed.", ex);
            Stop();
        }
    }

    private void Apply() => _scrollViewer.ChangeView(
        _horizontal ? _current : null,
        _horizontal ? null : _current,
        null,
        disableAnimation: true);

    private double CurrentOffset(bool horizontal) =>
        horizontal ? _scrollViewer.HorizontalOffset : _scrollViewer.VerticalOffset;

    private double MaxOffset(bool horizontal) =>
        horizontal ? _scrollViewer.ScrollableWidth : _scrollViewer.ScrollableHeight;
}
