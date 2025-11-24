// jobs.zig - Job control for zish
const std = @import("std");

pub const JobState = enum {
    running,
    stopped,
    done,
};

pub const Job = struct {
    id: u32, // job number (1, 2, 3...)
    pgid: std.posix.pid_t, // process group id
    command: []const u8, // command string
    state: JobState,

    pub fn deinit(self: *Job, allocator: std.mem.Allocator) void {
        allocator.free(self.command);
    }
};

pub const JobList = struct {
    jobs: std.ArrayList(Job),
    allocator: std.mem.Allocator,
    next_id: u32,

    pub fn init(allocator: std.mem.Allocator) JobList {
        return JobList{
            .jobs = std.ArrayList(Job){ .items = &.{}, .capacity = 0 },
            .allocator = allocator,
            .next_id = 1,
        };
    }

    pub fn deinit(self: *JobList) void {
        for (self.jobs.items) |*job| {
            job.deinit(self.allocator);
        }
        self.jobs.deinit(self.allocator);
    }

    pub fn addJob(self: *JobList, pgid: std.posix.pid_t, command: []const u8) !u32 {
        const job_id = self.next_id;
        self.next_id += 1;

        const cmd_copy = try self.allocator.dupe(u8, command);

        try self.jobs.append(self.allocator, Job{
            .id = job_id,
            .pgid = pgid,
            .command = cmd_copy,
            .state = .running,
        });

        return job_id;
    }

    pub fn getJob(self: *JobList, job_id: u32) ?*Job {
        for (self.jobs.items) |*job| {
            if (job.id == job_id) return job;
        }
        return null;
    }

    pub fn getJobByPgid(self: *JobList, pgid: std.posix.pid_t) ?*Job {
        for (self.jobs.items) |*job| {
            if (job.pgid == pgid) return job;
        }
        return null;
    }

    pub fn removeJob(self: *JobList, job_id: u32) void {
        var i: usize = 0;
        while (i < self.jobs.items.len) {
            if (self.jobs.items[i].id == job_id) {
                var job = self.jobs.orderedRemove(i);
                job.deinit(self.allocator);
                return;
            }
            i += 1;
        }
    }

    pub fn updateJobStates(self: *JobList) void {
        var i: usize = 0;
        while (i < self.jobs.items.len) {
            const job = &self.jobs.items[i];

            // check if process group still exists
            const result = std.posix.system.kill(@intCast(job.pgid), 0);

            if (result != 0) {
                // process group doesn't exist - job is done
                job.state = .done;
            }

            i += 1;
        }
    }

    pub fn cleanupDoneJobs(self: *JobList) void {
        var i: usize = 0;
        while (i < self.jobs.items.len) {
            if (self.jobs.items[i].state == .done) {
                var job = self.jobs.orderedRemove(i);
                job.deinit(self.allocator);
            } else {
                i += 1;
            }
        }
    }

    pub fn getCurrentJob(self: *JobList) ?*Job {
        if (self.jobs.items.len == 0) return null;
        return &self.jobs.items[self.jobs.items.len - 1];
    }
};
