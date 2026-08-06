using Microsoft.UI.Dispatching;

namespace Paster.Windows.Utilities;

public static class DispatcherQueueExtensions
{
    public static Task EnqueueAsync(this DispatcherQueue dispatcherQueue, Func<Task> action)
    {
        var completion = new TaskCompletionSource();
        dispatcherQueue.TryEnqueue(async () =>
        {
            try
            {
                await action();
                completion.SetResult();
            }
            catch (Exception ex)
            {
                completion.SetException(ex);
            }
        });
        return completion.Task;
    }
}
