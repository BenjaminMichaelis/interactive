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
/// Tests JupyterKernel.CreateAsync with a sender that replies synchronously inside
/// SendAsync -- the exact scenario that hangs on fast Linux GHA runners.
/// This test FAILS with the upstream code (subscribe after send) and PASSES with the fix.
/// </summary>
public class JupyterKernelCreateAsync_SynchronousSenderTests
{
    private sealed class SynchronousKernelInfoSender : IMessageSender
    {
        private readonly Subject<Message> _subject;

        public SynchronousKernelInfoSender(Subject<Message> subject) => _subject = subject;

        public Task SendAsync(Message message)
        {
            // Reply synchronously BEFORE returning -- simulates a fast in-process kernel
            // that completes within the same call stack as SendAsync.
            var reply = Message.CreateReply(
                new KernelInfoReply("5.3", "test", "1.0", new LanguageInfo("python", "3.10", "text/x-python", ".py")),
                message);
            _subject.OnNext(reply);
            return Task.CompletedTask;
        }
    }

    private sealed class SubjectReceiver : IMessageReceiver
    {
        public SubjectReceiver(Subject<Message> subject) => Messages = subject.AsObservable();
        public IObservable<Message> Messages { get; }
    }

    [Fact]
    public async Task CreateAsync_completes_when_sender_replies_synchronously()
    {
        // Arrange: hot Subject + synchronous sender that fires reply inside SendAsync
        var subject = new Subject<Message>();
        var sender = new SynchronousKernelInfoSender(subject);
        var receiver = new SubjectReceiver(subject);

        // Act: CreateAsync -> RequestKernelInfo -> RunOnKernelAsync
        // With the fix (subscribe before send) this completes immediately.
        // With upstream code (subscribe after send) the reply is missed and this hangs.
        var createTask = JupyterKernel.CreateAsync("test-kernel", sender, receiver);
        var completed = await Task.WhenAny(createTask, Task.Delay(TimeSpan.FromSeconds(5)));

        // Assert
        completed.Should().Be(createTask,
            "CreateAsync must complete even when the KernelInfoReply arrives synchronously " +
            "inside SendAsync (subscribe-before-send guarantees the reply is never missed)");

        using var kernel = await createTask;
        kernel.KernelInfo.LanguageName.Should().Be("python");
    }
}

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
