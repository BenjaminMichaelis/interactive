// Copyright (c) .NET Foundation and contributors. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

using System;
using System.Reactive.Linq;
using System.Reactive.Subjects;
using System.Reactive.Threading.Tasks;
using System.Threading;
using System.Threading.Tasks;
using FluentAssertions;
using Microsoft.DotNet.Interactive.Jupyter.Messaging;
using Microsoft.DotNet.Interactive.Jupyter.Protocol;
using Xunit;
using Message = Microsoft.DotNet.Interactive.Jupyter.Messaging.Message;

namespace Microsoft.DotNet.Interactive.Jupyter.Tests;

/// <summary>
/// Proves the race condition in JupyterKernel.RunOnKernelAsync where subscribing
/// to a hot observable AFTER sending the request causes missed replies when the
/// reply arrives synchronously (before subscription).
/// </summary>
public class RunOnKernelAsyncRaceConditionTests
{
    /// <summary>
    /// Simulates the BUGGY ordering: send first, then subscribe.
    /// When the reply arrives synchronously during SendAsync (before ToTask subscribes),
    /// the observable never produces a value and the task hangs indefinitely.
    /// </summary>
    [Fact]
    public async Task Buggy_order_subscribe_after_send_misses_synchronous_reply()
    {
        // Arrange: hot observable (Subject) simulating IMessageReceiver.Messages
        var subject = new Subject<Message>();

        var request = Message.Create(new ExecuteRequest("test"));

        // Build the observable pipeline (no subscription yet - just like the real code)
        var reply = subject.AsObservable()
            .ResponseOf(request)
            .Content()
            .OfType<ExecuteReplyOk>()
            .Take(1);

        // Act: simulate the BUGGY order — send first (which publishes reply), then subscribe
        // The sender synchronously publishes the reply to the subject
        var replyMessage = Message.CreateReply(new ExecuteReplyOk(), request);
        subject.OnNext(replyMessage); // Reply fires BEFORE subscription

        // Now subscribe (too late — the message was already emitted and missed)
        var replyTask = reply.ToTask(CancellationToken.None);

        // Assert: the task should NOT complete because the reply was missed
        var completedTask = await Task.WhenAny(replyTask, Task.Delay(TimeSpan.FromMilliseconds(500)));
        completedTask.Should().NotBe(replyTask,
            "the reply was emitted before subscription, so it should be permanently missed (race condition)");
    }

    /// <summary>
    /// Simulates the FIXED ordering: subscribe first, then send.
    /// The subscription is active when the reply arrives, so the task completes successfully.
    /// </summary>
    [Fact]
    public async Task Fixed_order_subscribe_before_send_captures_synchronous_reply()
    {
        // Arrange: hot observable (Subject) simulating IMessageReceiver.Messages
        var subject = new Subject<Message>();

        var request = Message.Create(new ExecuteRequest("test"));

        // Build the observable pipeline
        var reply = subject.AsObservable()
            .ResponseOf(request)
            .Content()
            .OfType<ExecuteReplyOk>()
            .Take(1);

        // Act: simulate the FIXED order — subscribe first, then send
        var replyTask = reply.ToTask(CancellationToken.None); // Subscribe BEFORE send

        // The sender synchronously publishes the reply to the subject
        var replyMessage = Message.CreateReply(new ExecuteReplyOk(), request);
        subject.OnNext(replyMessage); // Reply fires AFTER subscription — captured!

        // Assert: the task should complete successfully within a short timeout
        var completedTask = await Task.WhenAny(replyTask, Task.Delay(TimeSpan.FromMilliseconds(500)));
        completedTask.Should().Be(replyTask,
            "the reply was emitted after subscription, so it should be captured");

        var result = await replyTask;
        result.Should().BeOfType<ExecuteReplyOk>();
    }
}
