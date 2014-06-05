%-----------------------------------------------------------------------------%

:- module sync.
:- interface.

:- import_module io.
:- import_module maybe.

:- import_module database.
:- import_module dir_cache.
:- import_module imap.
:- import_module imap.types.
:- import_module inotify.
:- import_module prog_config.

:- type shortcut
    --->    shortcut(
                check_local :: check,
                check_remote :: check
            ).

:- type check
    --->    check
    ;       skip.

:- pred sync_mailboxes(prog_config::in, database::in, imap::in, inotify(S)::in,
    mailbox_pair::in, mod_seq_valzer::in, mod_seq_value::in, shortcut::in,
    update_method::in, maybe_error::out, dir_cache::in, dir_cache::out,
    io::di, io::uo) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module int.

:- include_module sync.download.
:- include_module sync.flags_local.
:- include_module sync.flags_remote.
:- include_module sync.update_local.
:- include_module sync.update_remote.
:- include_module sync.upload.

:- import_module sync.download.
:- import_module sync.flags_local.
:- import_module sync.flags_remote.
:- import_module sync.update_local.
:- import_module sync.update_remote.
:- import_module sync.upload.

:- import_module dir_cache.

%-----------------------------------------------------------------------------%

sync_mailboxes(Config, Db, IMAP, Inotify, MailboxPair, LastModSeqValzer,
        HighestModSeqValue, Shortcut, DirCacheUpdate, !:Res, !DirCache, !IO) :-
    Shortcut = shortcut(CheckLocal0, CheckRemote),
    % It might be better to get set of valid UIDs first, then use that
    % as part of update_db_remote_mailbox and for detecting expunges.
    (
        CheckRemote = check,
        update_db_remote_mailbox(Config, Db, IMAP, MailboxPair,
            LastModSeqValzer, HighestModSeqValue, !:Res, !IO)
    ;
        CheckRemote = skip,
        !:Res = ok
    ),
    force_check_local(Inotify, CheckLocal0, CheckLocal, !Res, !IO),
    (
        !.Res = ok,
        CheckLocal = check
    ->
        update_db_local_mailbox(Config, Db, Inotify, MailboxPair,
            DirCacheUpdate, !:Res, !DirCache, !IO)
    ;
        true
    ),
    (
        !.Res = ok,
        CheckRemote = check
    ->
        % Propagate flags first to allow pairings with previously-expunged
        % messages to be be reset, and thus downloaded in the following steps.
        propagate_flag_deltas_from_remote(Config, Db, MailboxPair,
            !:Res, !DirCache, !IO)
    ;
        true
    ),
    (
        !.Res = ok,
        CheckLocal = check
    ->
        propagate_flag_deltas_from_local(Config, Db, IMAP, MailboxPair,
            !:Res, !IO)
    ;
        true
    ),
    (
        !.Res = ok,
        download_unpaired_remote_messages(Config, Db, IMAP, MailboxPair,
            !:Res, !DirCache, !IO)
    ;
        !.Res = error(_)
    ),
    (
        !.Res = ok,
        upload_unpaired_local_messages(Config, Db, IMAP, MailboxPair,
            !.DirCache, !:Res, !IO)
    ;
        !.Res = error(_)
    ),
    (
        !.Res = ok,
        delete_expunged_pairings(Db, !:Res, !IO)
    ;
        !.Res = error(_)
    ).

:- pred force_check_local(inotify(S)::in, check::in, check::out,
    maybe_error::in, maybe_error::out, io::di, io::uo) is det.

force_check_local(Inotify, CheckLocal0, CheckLocal, Res0, Res, !IO) :-
    (
        Res0 = ok,
        CheckLocal0 = skip,
        get_queue_length(Inotify, ResQueue, !IO),
        (
            ResQueue = ok(Length),
            Res = ok,
            CheckLocal = ( Length > 0 -> check ; skip )
        ;
            ResQueue = error(Error),
            Res = error(Error),
            CheckLocal = skip
        )
    ;
        Res0 = ok,
        Res = ok,
        CheckLocal0 = check,
        CheckLocal = check
    ;
        Res0 = error(Error),
        Res = error(Error),
        CheckLocal = CheckLocal0
    ).

%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sts=4 sw=4 et
