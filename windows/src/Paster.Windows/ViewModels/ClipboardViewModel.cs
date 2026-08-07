using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using Paster.Windows.Models;
using Paster.Windows.Services;

namespace Paster.Windows.ViewModels;

public sealed class ClipboardViewModel : INotifyPropertyChanged
{
    private static readonly TimeSpan SearchDebounce = TimeSpan.FromMilliseconds(120);

    private readonly ClipboardDatabase _database;
    private readonly AppSettings _settings;
    private readonly PasteService _pasteService;
    private CancellationTokenSource? _pendingSearch;
    private string _searchText = string.Empty;
    private ClipboardItem? _selectedItem;

    public ObservableCollection<ClipboardItem> Items { get; } = [];

    public string SearchText
    {
        get => _searchText;
        set
        {
            if (SetField(ref _searchText, value))
            {
                ScheduleSearch();
            }
        }
    }

    public ClipboardItem? SelectedItem
    {
        get => _selectedItem;
        set => SetField(ref _selectedItem, value);
    }

    /// <summary>
    /// Bare count: the header sits next to the action buttons in a panel that can be under
    /// 300px wide, where a "{n} items" label is clipped mid-word.
    /// </summary>
    public string ItemCountText => $"{Items.Count}";

    public ClipboardViewModel(ClipboardDatabase database, AppSettings settings, PasteService pasteService)
    {
        _database = database;
        _settings = settings;
        _pasteService = pasteService;
    }

    /// <summary>
    /// Coalesces keystrokes and cancels the previous query, so two refreshes can never interleave
    /// their mutations of <see cref="Items"/>.
    /// </summary>
    private void ScheduleSearch()
    {
        _pendingSearch?.Cancel();
        var request = new CancellationTokenSource();
        _pendingSearch = request;
        _ = RunSearchAsync(request);
    }

    private async Task RunSearchAsync(CancellationTokenSource request)
    {
        try
        {
            await Task.Delay(SearchDebounce, request.Token);
            await RefreshAsync(request.Token);
        }
        catch (OperationCanceledException)
        {
            // Superseded by a newer keystroke.
        }
        catch (Exception ex)
        {
            AppLog.Error("Search refresh failed.", ex);
        }
        finally
        {
            if (ReferenceEquals(_pendingSearch, request))
            {
                _pendingSearch = null;
            }

            request.Dispose();
        }
    }

    public async Task RefreshAsync(CancellationToken cancellationToken = default)
    {
        var items = await _database.GetItemsAsync(SearchText, _settings.HistoryLimit, cancellationToken);
        if (cancellationToken.IsCancellationRequested)
        {
            return;
        }

        Merge(items);
    }

    /// <summary>
    /// Applies the query result in place, keyed on <see cref="ClipboardItem.Id"/>. Rebuilding the
    /// collection with Clear() + Add() would drop the selected instance and reset the scroll
    /// position on every keystroke.
    /// </summary>
    private void Merge(IReadOnlyList<ClipboardItem> incoming)
    {
        var selectedId = SelectedItem?.Id;
        var incomingIds = new HashSet<Guid>(incoming.Count);
        foreach (var item in incoming)
        {
            incomingIds.Add(item.Id);
        }

        for (var index = Items.Count - 1; index >= 0; index--)
        {
            if (!incomingIds.Contains(Items[index].Id))
            {
                Items.RemoveAt(index);
            }
        }

        for (var target = 0; target < incoming.Count; target++)
        {
            var fresh = incoming[target];
            var existing = IndexOf(fresh.Id, target);
            if (existing < 0)
            {
                Items.Insert(target, fresh);
                continue;
            }

            if (existing != target)
            {
                Items.Move(existing, target);
            }

            // Reuse the live instance so selection identity and any hydrated blobs survive.
            var current = Items[target];
            current.IsPinned = fresh.IsPinned;
            current.PinnedAt = fresh.PinnedAt;
            current.Text = fresh.Text;
            current.ThumbnailData = fresh.ThumbnailData;
        }

        SelectedItem = Items.FirstOrDefault(x => x.Id == selectedId) ?? Items.FirstOrDefault();
        OnPropertyChanged(nameof(ItemCountText));
    }

    private int IndexOf(Guid id, int startAt)
    {
        for (var index = startAt; index < Items.Count; index++)
        {
            if (Items[index].Id == id)
            {
                return index;
            }
        }

        for (var index = 0; index < startAt && index < Items.Count; index++)
        {
            if (Items[index].Id == id)
            {
                return index;
            }
        }

        return -1;
    }

    public async Task PasteSelectedAsync(bool plainText = false)
    {
        if (SelectedItem is null)
        {
            return;
        }

        await _pasteService.PasteAsync(SelectedItem, plainText);
    }

    public async Task CopySelectedAsync()
    {
        if (SelectedItem is not null)
        {
            await _pasteService.CopyAsync(SelectedItem);
        }
    }

    public async Task DeleteSelectedAsync()
    {
        if (SelectedItem is null)
        {
            return;
        }

        var item = SelectedItem;
        var selectedIndex = Items.IndexOf(item);
        await _database.DeleteAsync(item.Id);

        if (selectedIndex >= 0)
        {
            Items.RemoveAt(selectedIndex);
        }

        if (Items.Count == 0)
        {
            SelectedItem = null;
        }
        else
        {
            // Deleting keeps the cursor where it was rather than jumping back to the top.
            SelectedItem = Items[Math.Clamp(selectedIndex, 0, Items.Count - 1)];
        }

        OnPropertyChanged(nameof(ItemCountText));
    }

    public async Task TogglePinSelectedAsync()
    {
        if (SelectedItem is null)
        {
            return;
        }

        var item = SelectedItem;
        await _database.TogglePinAsync(item);

        var from = Items.IndexOf(item);
        if (from < 0)
        {
            return;
        }

        Items.RemoveAt(from);
        Items.Insert(InsertIndexFor(item), item);
        SelectedItem = item;
    }

    /// <summary>
    /// Position for an item whose sort keys just changed, using the same ordering as the SQL query.
    /// </summary>
    private int InsertIndexFor(ClipboardItem item)
    {
        for (var index = 0; index < Items.Count; index++)
        {
            if (ClipboardDatabase.DisplayOrder.Compare(item, Items[index]) < 0)
            {
                return index;
            }
        }

        return Items.Count;
    }

    /// <summary>
    /// Clears the unpinned history. The list is reloaded rather than emptied, because pinned rows
    /// survive the delete and have to stay on screen; clearing the collection outright would show
    /// an empty panel that disagrees with the database until the next refresh.
    /// </summary>
    public async Task ClearAllAsync()
    {
        await _database.ClearAsync();
        await RefreshAsync();
    }

    public void MoveSelection(int delta)
    {
        if (Items.Count == 0)
        {
            return;
        }

        var index = SelectedItem is null ? -1 : Items.IndexOf(SelectedItem);
        var next = Math.Clamp(index + delta, 0, Items.Count - 1);
        SelectedItem = Items[next];
    }

    public void SelectFirst() => SelectedItem = Items.FirstOrDefault();
    public void SelectLast() => SelectedItem = Items.LastOrDefault();

    public event PropertyChangedEventHandler? PropertyChanged;

    private bool SetField<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
        {
            return false;
        }

        field = value;
        OnPropertyChanged(propertyName);
        return true;
    }

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
}
