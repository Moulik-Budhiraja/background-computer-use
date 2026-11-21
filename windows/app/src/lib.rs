//! The engine and the tray app, as a library. Two programs run it: the tray
//! app (`BackgroundComputerUse.exe`, main.rs), and `bcu serve`, the engine as
//! a child process of a host app that shows agents in its own UI
//! (docs/embedding.md). Either way one process owns the agent screen, the
//! focus guard and the pipe, and serves agents' tool calls and hosts' requests.

pub mod apps;
pub mod browser;
pub mod capture;
pub mod engine;
pub mod gfx;
pub mod guard;
pub mod host;
pub mod input;
pub mod jpeg;
pub mod menus;
pub mod monitor;
pub mod navigate;
pub mod offscreen;
pub mod onboarding;
pub mod pipe;
pub mod recorder;
pub mod remote;
pub mod serve;
pub mod sessions;
pub mod setup;
pub mod snapshot;
pub mod stream;
pub mod tools;
pub mod tray;
pub mod ui;
pub mod updater;
pub mod win;
