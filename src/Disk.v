Require Import Storage.

Inductive dprog :=
  | DRead  (b:block) (rx:value -> dprog)
  | DWrite (b:block) ( v:value) (rx:dprog)
  | DHalt
  .

Record dstate := DSt {
  DSProg: dprog;
  DSDisk: storage
}.

(* An interpreter for the language that implements a log as a disk *)

Fixpoint dexec (p:dprog) (s:dstate) {struct p} : dstate :=
  let (_, dd) := s in
  match p with
  | DHalt         => s
  | DRead b rx    => dexec (rx (st_read dd b)) (DSt (rx (st_read dd b)) dd)
  | DWrite b v rx => dexec rx (DSt rx (st_write dd b v))
  end.

Definition drun (p:dprog) (s:storage) : storage :=
  DSDisk (dexec p (DSt p s)).

Inductive dsmstep : dstate -> dstate -> Prop :=
  | DsmHalt: forall d,
    dsmstep (DSt DHalt d) (DSt DHalt d)
  | DsmRead: forall d b rx,
    dsmstep (DSt (DRead b rx) d)
            (DSt (rx (st_read d b)) d)
  | DsmWrite: forall d b v rx,
    dsmstep (DSt (DWrite b v rx) d)
            (DSt rx (st_write d b v))
  .
