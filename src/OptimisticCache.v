Require Import CCL.

Require SepAuto.
Require Import Mem Pred AsyncDisk.
Require Import MemCache.
Require Import FunctionalExtensionality.
Require Import UpdList.

(* re-export WriteBuffer since it's part of external type signatures *)
Require Export WriteBuffer.

Notation Disk := (@mem addr addr_eq_dec valu).

Record CacheParams :=
  { cache : ident;
    vdisk : ident;
    vdisk_committed : ident; }.

Section OptimisticCache.

  Implicit Types (c:Cache) (wb:WriteBuffer).

  Definition cache_rep (d: DISK) c (vd0: Disk) :=
    forall a, match cache_get c a with
         | Present v dirty => vd0 a = Some v /\
                             if dirty then exists v0, d a = Some (v0, NoReader)
                             else d a = Some (v, NoReader)
         | Invalid => exists v0, d a = Some (v0, Pending) /\
                           vd0 a = Some v0
         | Missing => match vd0 a with
                     | Some v => d a = Some (v, NoReader)
                     | None => d a = None
                     end
         end.

  Definition wb_rep (vd0: Disk) wb (vd: Disk) :=
    forall a, match wb_get wb a with
         | Written v => vd a = Some v /\
                       exists v0, vd0 a = Some v0
         | WbMissing => vd a = vd0 a
         end.

  Definition no_pending_dirty c wb :=
    forall a, cache_get c a = Invalid ->
         wb_get wb a = WbMissing.

  Variable (P:CacheParams).
  Variable G:Protocol.

  Definition CacheRep d wb (vd0 vd:Disk) : heappred :=
    (exists c, cache P |-> val c *
          vdisk_committed P |-> absMem vd0 *
          vdisk P |-> absMem vd *
          [[ cache_rep d c vd0 ]] *
          [[ wb_rep vd0 wb vd ]] *
          [[ no_pending_dirty c wb ]]
    )%pred.

  Lemma CacheRep_unfold : forall F m d wb vd0 vd,
      (F * CacheRep d wb vd0 vd)%pred m ->
      wb_rep vd0 wb vd /\
      exists c, (F * cache P |-> val c * vdisk_committed P |-> absMem vd0 * vdisk P |-> absMem vd)%pred m /\
           cache_rep d c vd0 /\
           no_pending_dirty c wb.
  Proof.
    unfold CacheRep; intros.
    SepAuto.destruct_lifts; auto.
    intuition.
    eexists; intuition eauto.
  Qed.

  Lemma CacheRep_fold : forall F m d wb vd0 vd c,
      (F * cache P |-> val c *
       vdisk_committed P |-> absMem vd0 *
       vdisk P |-> absMem vd)%pred m ->
      cache_rep d c vd0 ->
      wb_rep vd0 wb vd ->
      no_pending_dirty c wb ->
      (F * CacheRep d wb vd0 vd)%pred m.
  Proof.
    unfold CacheRep; intros.
    SepAuto.pred_apply; SepAuto.cancel.
  Qed.

  Ltac cacherep :=
    repeat match goal with
           | [ H: (_ * CacheRep _ _ _ _)%pred _ |- _ ] =>
             apply CacheRep_unfold in H; safe_intuition; deex
           | [ |- (_ * CacheRep _ _ _ _)%pred _ ] =>
             eapply CacheRep_fold
           end.

  Definition BufferRead wb a :=
    match wb_get wb a with
    | Written v => Ret (Some v)
    | WbMissing => Ret (None)
    end.

  Definition ClearPending c wb a :=
    v <- WaitForRead a;
      let c' := add_entry Clean c a v in
      _ <- Assgn (cache P) c';
        (* note that v could also be added to the local write buffer (not
           returned since it isn't modified), which should improve
           performance *)
        Ret v.

  Definition CacheRead wb a :=
    r <- BufferRead wb a;
      match r with
      | Some v => Ret (Some v, wb)
      | None => c <- Get _ (cache P);
                 match cache_get c a with
                 | Present v _ => Ret (Some v, wb)
                 | Missing => _ <- BeginRead a;
                               let c' := mark_pending c a in
                               _ <- Assgn (cache P) c';
                                 Ret (None, wb)
                 | Invalid => v <- ClearPending c wb a;
                               Ret (Some v, wb)
                 end
      end.

  Ltac solve_cache :=
    unfold CacheRep; intuition;
    repeat match goal with
           | [ a: addr, H: cache_rep _ _ _ |- _ ] =>
             specialize (H a)
           | [ a: addr, H: wb_rep _ _ _ |- _ ] =>
             specialize (H a)
           | [ a: addr, H: no_pending_dirty _ _ |- _ ] =>
             specialize (H a)
           end;
    repeat simpl_match;
    repeat deex;
    intuition eauto; try congruence.

  Lemma exists_tuple : forall A B P,
      (exists a b, P (a, b)) ->
      exists (a: A * B), P a.
  Proof.
    intros.
    repeat deex; eauto.
  Qed.

  Ltac simplify :=
    repeat match goal with
           | [ H: context[let (n, m) := ?a in _] |- _ ] =>
             let n := fresh n in
             let m := fresh m in
             destruct a as [m n]
           | [ |- exists (_: _ * _), _ ] => apply exists_tuple
           | [ H: exists _, _ |- _ ] => deex
           | _ => progress simpl in *
           | _ => progress subst
           | _ => progress simpl_match
           | _ => progress autorewrite with upd cache in *
           | _ => intuition eauto
           end.

  Lemma Buffer_hit:
    forall (wb : WriteBuffer) (a : addr) (v : valu),
      wb_get wb a = Written v ->
      forall (vd0 vd : Disk) (v0 : valu), wb_rep vd0 wb vd -> vd a = Some v0 -> v = v0.
  Proof.
    solve_cache.
  Qed.

  Hint Resolve Buffer_hit.

  Definition BufferRead_ok : forall tid wb a,
      cprog_spec G tid
                 (fun '(F, vd0, vd, v0) '(sigma_i, sigma) =>
                    {| precondition :=
                         (F * CacheRep (Sigma.disk sigma) wb vd0 vd)%pred (Sigma.mem sigma) /\
                         vd a = Some v0;
                       postcondition :=
                         fun '(sigma_i', sigma') r =>
                           sigma' = sigma /\
                           match r with
                           | Some v => v = v0
                           | None => wb_get wb a = WbMissing
                           end /\
                           sigma_i' = sigma_i|})
                 (BufferRead wb a).
  Proof.
    unfold BufferRead; intros.

    case_eq (wb_get wb a); intros.
    step.
    simplify.

    cacherep.
    step.
    simplify.

    step.
    simplify.

    step.
    simplify.
  Qed.

  Hint Extern 0 {{ BufferRead _ _; _ }} => apply BufferRead_ok : prog.

  Lemma CacheRep_invalid:
    forall (c : Cache) (wb : WriteBuffer) (a : addr) d (vd0 vd : Disk) (v0 : valu),
      cache_rep d c vd0 ->
      wb_rep vd0 wb vd ->
      no_pending_dirty c wb ->
      cache_get c a = Invalid -> vd a = Some v0 -> d a = Some (v0, Pending).
  Proof.
    intros.
    destruct (wb_get wb a) eqn:?;
             solve_cache.
  Qed.

  Hint Resolve CacheRep_invalid.

  Lemma cache_rep_add_clean:
    forall (c : Cache) (wb : WriteBuffer) (a : addr) (vd0 vd : Disk)
      (v0 : valu) (d : DISK),
      cache_rep d c vd0 ->
      wb_rep vd0 wb vd ->
      no_pending_dirty c wb ->
      vd a = Some v0 ->
      cache_get c a = Invalid ->
      forall d' : DISK,
        d' = upd d a (v0, NoReader) -> cache_rep d' (add_entry Clean c a v0) vd0.
  Proof.
    intros.
    unfold cache_rep; intros a'.
    repeat match goal with
           | [ H: _ |- _ ] =>
             specialize (H a')
           end.
    destruct (addr_eq_dec a a'); simplify.
    congruence.
  Qed.

  Lemma no_pending_dirty_add_clean:
    forall (c : Cache) (wb : WriteBuffer) (a : addr) (v0 : valu),
      no_pending_dirty c wb -> no_pending_dirty (add_entry Clean c a v0) wb.
  Proof.
    unfold no_pending_dirty; intros.
    specialize (H a0).
    destruct (addr_eq_dec a a0); simplify.
    congruence.
  Qed.

  Hint Resolve cache_rep_add_clean no_pending_dirty_add_clean.

  Hint Extern 3 (_ = _) => congruence.

  Theorem ClearPending_ok : forall tid c wb a,
      cprog_spec G tid
                 (fun '(F, vd0, vd, v0) '(sigma_i, sigma) =>
                    {| precondition :=
                         (F * cache P |-> val c *
                          vdisk_committed P |-> absMem vd0 *
                          vdisk P |-> absMem vd)%pred (Sigma.mem sigma) /\
                         cache_rep (Sigma.disk sigma) c vd0 /\
                         wb_rep vd0 wb vd /\
                         no_pending_dirty c wb /\
                         cache_get c a = Invalid /\
                         vd a = Some v0;
                       postcondition :=
                         fun '(sigma_i', sigma') r =>
                           (exists c',
                             (F * cache P |-> val c' *
                              vdisk_committed P |-> absMem vd0 *
                              vdisk P |-> absMem vd)%pred (Sigma.mem sigma') /\
                             cache_rep (Sigma.disk sigma') c' vd0 /\
                             wb_rep vd0 wb vd /\
                             no_pending_dirty c' wb /\
                             cache_get c' a = Present v0 Clean) /\
                           r = v0 /\
                           Sigma.hm sigma' = Sigma.hm sigma /\
                           sigma_i' = sigma_i |})
                 (ClearPending c wb a).
  Proof.
    unfold ClearPending.
    hoare.
    simplify.
    descend; intuition eauto.

    step.
    simplify.
    descend; intuition eauto.
    SepAuto.pred_apply; SepAuto.cancel.

    step.
    simplify.

    descend; intuition simplify.
    SepAuto.pred_apply; SepAuto.cancel.
  Qed.

  Hint Extern 0 {{ ClearPending _ _ _; _ }} => apply ClearPending_ok : prog.

  Lemma Buffer_miss_cache_hit:
    forall (wb : WriteBuffer) (a : addr) d
      (vd0 vd : Disk) (v0 : valu),
      wb_rep vd0 wb vd ->
      vd a = Some v0 ->
      forall c : Cache,
        cache_rep d c vd0 ->
        wb_get wb a = WbMissing ->
        forall (v : valu) (b : DirtyBit), cache_get c a = Present v b -> v = v0.
  Proof.
    solve_cache.
  Qed.

  Hint Resolve Buffer_miss_cache_hit.

  Lemma CacheRep_missing:
    forall (wb : WriteBuffer) (a : addr) (vd0 vd : Disk) (v0 : valu),
      wb_rep vd0 wb vd ->
      vd a = Some v0 ->
      forall (c : Cache) (d : DISK),
        cache_rep d c vd0 ->
        wb_get wb a = WbMissing -> cache_get c a = Missing -> d a = Some (v0, NoReader).
  Proof.
    solve_cache.
    rewrite H in *.
    simpl_match; auto.
  Qed.

  Hint Resolve CacheRep_missing.

  Lemma CacheRep_mark_pending:
    forall (a : addr) (vd0 vd : Disk) (v0 : valu) (c : Cache) wb,
      vd a = Some v0 ->
      wb_rep vd0 wb vd ->
      forall d : DISK,
        cache_rep d c vd0 ->
        cache_get c a = Missing ->
        wb_get wb a = WbMissing ->
        forall d' : DISK,
          d' = upd d a (v0, Pending) -> cache_rep d' (mark_pending c a) vd0.
  Proof.
    unfold cache_rep; intros; subst.
    repeat match goal with
           | [ H: _ |- _ ] =>
             specialize (H a0)
           end.
    destruct (addr_eq_dec a a0); simplify.
  Qed.

  Hint Resolve CacheRep_mark_pending.

  Lemma no_pending_dirty_add_pending:
    forall (wb : WriteBuffer) (a : addr) (c : Cache),
      no_pending_dirty c wb ->
      wb_get wb a = WbMissing -> no_pending_dirty (mark_pending c a) wb.
  Proof.
    unfold no_pending_dirty; intros.
    destruct (addr_eq_dec a a0); simplify.
  Qed.

  Hint Resolve no_pending_dirty_add_pending.

  Definition CacheRead_ok : forall tid wb a,
      cprog_spec G tid
                 (fun '(F, vd0, vd, v0) '(sigma_i, sigma) =>
                    {| precondition :=
                         (F * CacheRep (Sigma.disk sigma) wb vd0 vd)%pred (Sigma.mem sigma) /\
                         vd a = Some v0;
                       postcondition :=
                         fun '(sigma_i', sigma') '(r, wb') =>
                           (F * CacheRep (Sigma.disk sigma') wb vd0 vd)%pred (Sigma.mem sigma') /\
                           Sigma.hm sigma' = Sigma.hm sigma /\
                           match r with
                           | Some v => v = v0
                           | None => True
                           end /\
                           sigma_i' = sigma_i |})
                 (CacheRead wb a).
  Proof.
    unfold CacheRead.
    step.
    simplify.
    cacherep.

    descend; intuition eauto.
    cacherep; eauto.

    destruct r; step; simplify.
    cacherep; eauto.
    descend; intuition eauto.
    SepAuto.pred_apply; SepAuto.cancel.

    rename r into c'.
    case_eq (cache_get c' a); intros;
      hoare; simplify.
    cacherep; eauto.

    descend; intuition eauto.
    step; simplify.
    cacherep; eauto.

    descend; intuition eauto.

    step; simplify.
    descend; intuition eauto.
    SepAuto.pred_apply; SepAuto.cancel.

    step; simplify.
    cacherep; eauto.
    SepAuto.pred_apply; SepAuto.cancel.
  Qed.

  Definition CacheWrite wb a v : @cprog St _ :=
    m <- Get (St:=St);
      _ <- match cache_get (cache m) a with
          | Invalid => _ <- ClearPending m wb a;
                        Ret tt
          | _ => Ret tt
          end;
      _ <- GhostUpdate (fun _ s => set_vdisk s (upd (vdisk s) a v));
      Ret (tt, wb_add wb a v).

  Lemma CacheRep_write:
    forall (wb : WriteBuffer) (a : addr) (v : valu) (d : DISK)
      (m : Mem St) (s : Abstraction St) (hm : hashmap)
      (a0 : valu),
      CacheRep wb (state d m s hm) ->
      vdisk s a = Some a0 ->
      cache_get (cache m) a <> Invalid ->
      CacheRep (wb_add wb a v) (state d m (set_vdisk s (upd (vdisk s) a v)) hm).
  Proof.
    unfold CacheRep; intuition; simpl in *; simplify.
    - intro a'.
      destruct (addr_eq_dec a a'); simplify.
      solve_cache.
      case_eq (wb_get wb a'); intros; simpl_match;
        intuition eauto.
      exists a0; congruence.

      solve_cache.
    - intro a'; intros.
      destruct (addr_eq_dec a a'); simplify.
  Qed.

  Hint Resolve CacheRep_write.

  Hint Extern 2 (cache_get _ _ <> _) => congruence.

  Theorem CacheWrite_ok : forall tid wb a v,
      cprog_spec G tid
                 (fun v0 '(sigma_i, sigma) =>
                    {| precondition :=
                         CacheRep wb sigma /\
                         vdisk (Sigma.s sigma) a = Some v0;
                       postcondition :=
                         fun '(sigma_i', sigma') '(_, wb') =>
                           CacheRep wb' sigma' /\
                           locally_modified sigma sigma' /\
                           vdisk (Sigma.s sigma') = upd (vdisk (Sigma.s sigma)) a v  /\
                           vdisk_committed (Sigma.s sigma') = vdisk_committed (Sigma.s sigma) /\
                           Sigma.hm sigma' = Sigma.hm sigma /\
                           sigma_i' = sigma_i |})
                 (CacheWrite wb a v).
  Proof.
    unfold CacheWrite.
    hoare.
    rename r into m'.
    case_eq (cache_get (cache m') a);
      hoare.

    state upd sigma, sigma'; intuition eauto.
  Qed.

  Fixpoint add_writes (c:Cache) (wrs: list (addr * valu)) :=
    match wrs with
    | nil => c
    | (a,v) :: wrs' => add_entry Dirty (add_writes c wrs') a v
    end.

  Definition upd_with_buffer (c:Cache) (wb:WriteBuffer) :=
    add_writes c (wb_writes wb).

  Definition CacheCommit wb :=
    m <- Get (St:=St);
      let c := cache m in
      _ <- Assgn (set_cache m (upd_with_buffer c wb));
        _ <- GhostUpdate (fun _ s => set_vdisk0 s (vdisk s));
        Ret tt.

  Lemma no_pending_dirty_empty : forall c,
      no_pending_dirty c empty_writebuffer.
  Proof.
    unfold no_pending_dirty; eauto.
  Qed.

  Lemma wb_rep_empty : forall vd,
      wb_rep vd empty_writebuffer vd.
  Proof.
    unfold wb_rep; intros; simpl; auto.
  Qed.

  Hint Resolve no_pending_dirty_empty wb_rep_empty.

  Theorem wb_rep_upd_all_ext : forall wb vd0 (vd: Disk) (a: addr),
      wb_rep vd0 wb vd ->
      vd a = upd_all (AEQ:=addr_eq_dec) vd0 (wb_writes wb) a.
  Proof.
    intro.
    assert (forall a v, wb_get wb a = Written v <-> List.In (a, v) (wb_writes wb)).
    { intros; apply wb_get_writes. }
    intros.
    specialize (H a).
    pose proof (wb_writes_nodup_addr wb).
    move H1 at top.
    generalize dependent (wb_writes wb).
    induction l; intros; subst; simpl in *.
    - specialize (H0 a).
      case_eq (wb_get wb a); intros; simpl_match; auto.
      exfalso.
      eapply H; eauto.
    - destruct a0 as [a' v].
      destruct (addr_eq_dec a a'); subst; autorewrite with upd.
      + destruct (H v) as [H' ?]; clear H'.
        intuition.
        specialize (H0 a'); simpl_match; intuition.
      + simpl in *.
        inversion H1; subst; intuition.

        case_eq (wb_get wb a); intuition.
        specialize (H v0); intuition.
        congruence.
        erewrite upd_all_nodup_in by eauto.
        specialize (H0 a); simpl_match; intuition eauto.

        destruct (list_addr_in_dec addr_eq_dec a l);
          autorewrite with upd.
        destruct s.
        specialize (H x); intuition; congruence.
        specialize (H0 a); simpl_match; eauto.
  Qed.

  Corollary wb_rep_upd_all : forall vd0 wb vd,
      wb_rep vd0 wb vd ->
      vd = upd_all vd0 (wb_writes wb).
  Proof.
    intros.
    extensionality a.
    apply wb_rep_upd_all_ext; auto.
  Qed.

  Lemma cache_rep_add_dirty:
    forall (d : DISK) (a : addr) (v : valu) (c : Cache) (vd0 : Disk),
      cache_get c a <> Invalid ->
      (exists v0, vd0 a = Some v0) ->
      cache_rep d c vd0 ->
      cache_rep d (add_entry Dirty c a v) (upd vd0 a v).
  Proof.
    unfold cache_rep; intros; repeat deex.
    specialize (H1 a0).
    destruct (addr_eq_dec a a0); subst; simplify; intuition eauto.
    case_eq (cache_get c a0); intros; simpl_match; intuition.
    destruct b; repeat deex; intuition eauto.
    eauto.
  Qed.

  Lemma add_writes_same_invalid : forall ws c a,
      cache_get (add_writes c ws) a = Invalid ->
      cache_get c a = Invalid.
  Proof.
    induction ws; intros; simpl in *; auto.
    destruct a as [a v].
    destruct (addr_eq_dec a a0); subst;
      autorewrite with cache in H; auto.
    congruence.
  Qed.

  Hint Resolve upd_all_incr_domain.

  Lemma CacheRep_commit:
    forall (wb : WriteBuffer) (d : DISK) (m : Mem St)
      (s : Abstraction St) (hm : hashmap),
      CacheRep wb (state d m s hm) ->
      CacheRep empty_writebuffer
               (state d (set_cache m (upd_with_buffer (cache m) wb))
                      (set_vdisk0 s (vdisk s)) hm).
  Proof.
    unfold CacheRep; simpl; intuition; simplify.
    unfold upd_with_buffer.

    erewrite wb_rep_upd_all by eauto.
    assert (forall a v, List.In (a,v) (wb_writes wb) ->
                   wb_get wb a = Written v).
    intros; apply wb_get_writes; auto.
    generalize dependent (wb_writes wb); intros.
    induction l; simpl; eauto.
    destruct a as [a v].
    pose proof (H1 a v); simpl in *.
    match type of H3 with
    | ?P -> _ => let HP := fresh in
               assert P as HP by eauto;
                 specialize (H3 HP);
                 clear HP
    end.

    eapply cache_rep_add_dirty; eauto.
    - intro Hinvalid.
      apply add_writes_same_invalid in Hinvalid.
      specialize (H2 a); intuition auto.
      congruence.
    - specialize (H a); simpl_match; intuition eauto.
  Qed.

  Hint Resolve CacheRep_commit.

  Definition CacheCommit_ok : forall tid wb,
      cprog_spec G tid
                 (fun (_:unit) '(sigma_i, sigma) =>
                    {| precondition :=
                         CacheRep wb sigma;
                       postcondition :=
                         fun '(sigma_i', sigma') _ =>
                           CacheRep empty_writebuffer sigma' /\
                           locally_modified sigma sigma' /\
                           vdisk_committed (Sigma.s sigma') = vdisk (Sigma.s sigma) /\
                           vdisk (Sigma.s sigma') = vdisk (Sigma.s sigma) /\
                           Sigma.hm sigma' = Sigma.hm sigma /\
                           sigma_i' = sigma_i |})
                 (CacheCommit wb).
  Proof.
    unfold CacheCommit.
    hoare.
  Qed.

  Definition CacheAbort : @cprog St _ :=
    _ <- GhostUpdate (fun _ s => set_vdisk s (vdisk_committed s));
      Ret tt.

  Lemma CacheRep_abort:
    forall (wb : WriteBuffer) (d : DISK) (m : Mem St)
      (s : Abstraction St) (hm : hashmap),
      CacheRep wb (state d m s hm) ->
      CacheRep empty_writebuffer (state d m (set_vdisk s (vdisk_committed s)) hm).
  Proof.
    unfold CacheRep; simpl; intuition; simplify.
  Qed.

  Hint Resolve CacheRep_abort.

  Definition CacheAbort_ok : forall tid,
      cprog_spec G tid
                 (fun wb '(sigma_i, sigma) =>
                    {| precondition :=
                         CacheRep wb sigma;
                       postcondition :=
                         fun '(sigma_i', sigma') _ =>
                           CacheRep empty_writebuffer sigma' /\
                           locally_modified sigma sigma' /\
                           vdisk (Sigma.s sigma') = vdisk_committed (Sigma.s sigma) /\
                           vdisk_committed (Sigma.s sigma') = vdisk_committed (Sigma.s sigma) /\
                           Sigma.hm sigma' = Sigma.hm sigma /\
                           sigma_i' = sigma_i |})
                 (CacheAbort).
  Proof.
    unfold CacheAbort.
    hoare.
  Qed.

End OptimisticCache.

Arguments St OtherSt : clear implicits.

(* Local Variables: *)
(* company-coq-local-symbols: (("Sigma" . ?Σ) ("sigma" . ?σ) ("sigma'" . (?σ (Br . Bl) ?'))) *)
(* End: *)