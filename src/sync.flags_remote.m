%-----------------------------------------------------------------------------%

:- module sync.flags_remote.
:- interface.

:- import_module log.
:- import_module maybe_result.

:- pred propagate_flag_deltas_from_local(log::in, prog_config::in,
    database::in, imap::in, mailbox_pair::in, maybe_result::out,
    io::di, io::uo) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module integer.
:- import_module list.
:- import_module set.
:- import_module string.

:- import_module flag_delta.
:- import_module log_help.
:- import_module maildir.

%-----------------------------------------------------------------------------%

propagate_flag_deltas_from_local(Log, _Config, Db, IMAP, MailboxPair, Res, !IO)
        :-
    search_pending_flag_deltas_from_local(Db, MailboxPair, ResSearch, !IO),
    (
        ResSearch = ok(Pendings),
        list.length(Pendings, Total),
        list.foldl3(propagate_flag_deltas_from_local_2(Log, Db, IMAP, Total),
            Pendings, ok, Res, 1, _Count, !IO)
    ;
        ResSearch = error(Error),
        Res = error(Error)
    ).

:- pred propagate_flag_deltas_from_local_2(log::in, database::in, imap::in,
    int::in, pending_flag_deltas::in, maybe_result::in, maybe_result::out,
    int::in, int::out, io::di, io::uo) is det.

propagate_flag_deltas_from_local_2(Log, Db, IMAP, Total, Pending, Res0, Res,
        Count, Count + 1, !IO) :-
    (
        Res0 = ok,
        propagate_flag_deltas_from_local_3(Log, Db, IMAP, Pending, Count,
            Total, Res, !IO)
    ;
        ( Res0 = eof
        ; Res0 = error(_)
        ),
        Res = Res0
    ).

:- pred propagate_flag_deltas_from_local_3(log::in, database::in, imap::in,
    pending_flag_deltas::in, int::in, int::in, maybe_result::out,
    io::di, io::uo) is det.

propagate_flag_deltas_from_local_3(Log, Db, IMAP, Pending, Count, Total, Res,
        !IO) :-
    Pending = pending_flag_deltas(PairingId,
        MaybeUnique, LocalFlags0, LocalExpunged,
        MaybeUID, RemoteFlags0, RemoteExpunged),
    imply_deleted_flag(LocalExpunged, LocalFlags0, LocalFlags1),
    imply_deleted_flag(RemoteExpunged, RemoteFlags0, RemoteFlags1),
    apply_flag_deltas(RemoteFlags1, RemoteFlags, LocalFlags1, LocalFlags),

    Flags0 = RemoteFlags0 ^ cur_set,
    Flags = RemoteFlags ^ cur_set,
    AddFlags = Flags `difference` Flags0,
    RemoveFlags = Flags0 `difference` Flags,
    (
        MaybeUID = yes(UID),
        (
            set.empty(AddFlags),
            set.empty(RemoveFlags)
        ->
            Res0 = ok
        ;
            log_remote_flag_update(Log, UID, Count, Total, !IO),
            store_remote_flags_add_rm(Log, IMAP, UID, AddFlags, RemoveFlags,
                Res0, !IO)
        ),
        ( Res0 = ok ->
            record_local_flag_deltas_applied_to_remote(Db, PairingId,
                LocalFlags, RemoteFlags, Res1, !IO),
            Res = from_maybe_error(Res1)
        ;
            Res = Res0
        )
    ;
        MaybeUID = no,
        % If the remote message was previously expunged, but the local message
        % was undeleted, then reset the pairing so that the message can be
        % re-added to the remote mailbox with a new UID.
        (
            MaybeUnique = yes(uniquename(Unique)),
            RemoteExpunged = expunged,
            contains(RemoveFlags, system(deleted))
        ->
            log_notice(Log, "Resurrecting message " ++ Unique, !IO),
            reset_pairing_remote_message(Db, PairingId, Res0, !IO)
        ;
            record_local_flag_deltas_inapplicable_to_remote(Db,
                PairingId, LocalFlags, Res0, !IO)
        ),
        Res = from_maybe_error(Res0)
    ).

:- pred log_remote_flag_update(log::in, uid::in, int::in, int::in,
    io::di, io::uo) is det.

log_remote_flag_update(Log, uid(UID), Count, Total, !IO) :-
    log_info(Log,
        format("Store UID %s flags (%d of %d)",
            [s(to_string(UID)), i(Count), i(Total)]), !IO).

:- pred store_remote_flags_add_rm(log::in, imap::in, uid::in,
    set(flag)::in, set(flag)::in, maybe_result::out, io::di, io::uo) is det.

store_remote_flags_add_rm(Log, IMAP, UID, AddFlags, RemoveFlags, Res, !IO) :-
    % Would it be preferable to read back the actual flags from the server?
    store_remote_flags_change(Log, IMAP, UID, remove, RemoveFlags, Res0, !IO),
    ( Res0 = ok ->
        store_remote_flags_change(Log, IMAP, UID, add, AddFlags, Res, !IO)
    ;
        Res = Res0
    ).

:- pred store_remote_flags_change(log::in, imap::in, uid::in,
    store_operation::in, set(flag)::in, maybe_result::out, io::di, io::uo)
    is det.

store_remote_flags_change(Log, IMAP, UID, Operation, ChangeFlags, Res, !IO) :-
    ( set.empty(ChangeFlags) ->
        Res = ok
    ;
        uid_store(IMAP, singleton_sequence_set(UID), Operation, silent,
            to_sorted_list(ChangeFlags), Res0, !IO),
        (
            Res0 = ok(result(Status, Text, Alerts)),
            report_alerts(Log, Alerts, !IO),
            (
                Status = ok_with_data(_),
                Res = ok
            ;
                ( Status = no
                ; Status = bad
                ; Status = bye
                ; Status = continue
                ),
                Res = error("unexpected response to UID STORE: " ++ Text)
            )
        ;
            Res0 = eof,
            Res = eof
        ;
            Res0 = error(Error),
            Res = error(Error)
        )
    ).

%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sts=4 sw=4 et
