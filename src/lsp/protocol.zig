const std = @import("std");

pub const InitializeParams = struct {
    processId: ?i32 = null,
    rootUri: ?[]const u8 = null,
    capabilities: Capabilities = .{},
};

pub const Capabilities = struct {
    // Minimal capabilities for now
};

pub const InitializeRequest = struct {
    jsonrpc: []const u8 = "2.0",
    id: usize,
    method: []const u8 = "initialize",
    params: InitializeParams,
};

pub const InitializedNotification = struct {
    jsonrpc: []const u8 = "2.0",
    method: []const u8 = "initialized",
    params: struct {} = .{},
};

pub const TextDocumentItem = struct {
    uri: []const u8,
    languageId: []const u8,
    version: i32,
    text: []const u8,
};

pub const DidOpenTextDocumentParams = struct {
    textDocument: TextDocumentItem,
};

pub const DidOpenNotification = struct {
    jsonrpc: []const u8 = "2.0",
    method: []const u8 = "textDocument/didOpen",
    params: DidOpenTextDocumentParams,
};

pub const VersionedTextDocumentIdentifier = struct {
    uri: []const u8,
    version: i32,
};

pub const TextDocumentContentChangeEvent = struct {
    text: []const u8,
};

pub const DidChangeTextDocumentParams = struct {
    textDocument: VersionedTextDocumentIdentifier,
    contentChanges: []const TextDocumentContentChangeEvent,
};

pub const DidChangeNotification = struct {
    jsonrpc: []const u8 = "2.0",
    method: []const u8 = "textDocument/didChange",
    params: DidChangeTextDocumentParams,
};

pub const TextDocumentIdentifier = struct {
    uri: []const u8,
};

pub const DidSaveTextDocumentParams = struct {
    textDocument: TextDocumentIdentifier,
};

pub const DidSaveNotification = struct {
    jsonrpc: []const u8 = "2.0",
    method: []const u8 = "textDocument/didSave",
    params: DidSaveTextDocumentParams,
};

pub const DidCloseTextDocumentParams = struct {
    textDocument: TextDocumentIdentifier,
};

pub const DidCloseNotification = struct {
    jsonrpc: []const u8 = "2.0",
    method: []const u8 = "textDocument/didClose",
    params: DidCloseTextDocumentParams,
};

pub const CompletionParams = struct {
    textDocument: struct {
        uri: []const u8,
    },
    position: struct {
        line: usize,
        character: usize,
    },
};

pub const CompletionRequest = struct {
    jsonrpc: []const u8 = "2.0",
    id: usize,
    method: []const u8 = "textDocument/completion",
    params: CompletionParams,
};

pub const Position = struct {
    line: usize,
    character: usize,
};

pub const DefinitionParams = struct {
    textDocument: struct {
        uri: []const u8,
    },
    position: Position,
};

pub const DefinitionRequest = struct {
    jsonrpc: []const u8 = "2.0",
    id: usize,
    method: []const u8 = "textDocument/definition",
    params: DefinitionParams,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

pub const Diagnostic = struct {
    range: Range,
    severity: ?i32 = null,
    message: []const u8,
};

pub const PublishDiagnosticsParams = struct {
    uri: []const u8,
    diagnostics: []Diagnostic,
};
