MODULE Main;

(* Threading stress-test.

   Create a number of threads.  n is specified via nPer, It is
   reasonable for nPer to be from 1 to a few hundred.  nPer defaults
   to 3 but can be set by the -n command-line switch.

   Other command-line switches:

   -wait <steps>  
      how many one-second waits to execute between prints (default 10)

   -iters <iters>
      how many iterations to run for (default 10)

   -tests <test1>,<test2>,...
      comma-separated list of tests (default all types)

   The threads created are of five types.  Each type of thread starts
   by sleeping for a while, to give the other threads a chance to be 
   created.

   The threads are of the following types:
   
   1. Reader -- continuously read the contents of the file "hohum",
      created during startup in CWD by the main thread.
 
   2. Forker -- repeatedly fork the Unix process "sleep 1" using
      Process.Create.
 
   3. Allocator -- repeatedly allocate heap memory and perform 
      meaningless operations on it.

   4. Creator -- repeatedly fork a simple Thread.T that does nothing
      and exits.  Wait for it to exit before forking another.

   5. Locker -- repeatedly increment or decrement a single integer
      variable from within a MUTEX-protected critical section.

   Each thread writes the the it performs an operation to the times1 
   array.  The times1 array is copied by the main thread, every 10+ 
   seconds, into the times2 array.  No locks are used to synchronize 
   this copying activity as we don't want to introduce too many possible
   places things could deadlock.

   The main thread then prints out how long ago the thread that has not
   written times1 last wrote that array.

   Note that Fmt.Int in the main thread allocates memory and therefore
   acquires locks in ThreadPThread.m3, the file which the program is
   mainly intended to test.  The design is based on a knowledge of the
   internal behavior of ThreadPThread.m3 and also on a knowledge of the
   misbehavior of existing, highly multithreaded applications.

   Author: Mika Nystrom <mika@alum.mit.edu>

   Copyright (c) 2011 Generation Capital Ltd.  All rights reserved.

   Permission to use, copy, modify, and distribute this software            
   and its documentation for any purpose and without fee is hereby         
   granted, provided that the above copyright notice appear in all        
   copies. Generation Capital Ltd. makes no representations
   about the suitability of this software for any purpose. It is         
   provided "as is" without express or implied warranty.

 *)

IMPORT Thread, Rd, FileRd, Wr, FileWr, Process, IO;
IMPORT Time;
IMPORT Fmt, IntArraySort;
IMPORT Atom, AtomList;
IMPORT OSError;
IMPORT ParseParams;
IMPORT Stdio;
IMPORT Text;

<* FATAL Thread.Alerted *>

CONST InitPause = 1.0d0;

TYPE Closure = Thread.Closure OBJECT id : CARDINAL END;

PROCEDURE MakeReaderThread(i : CARDINAL) =
  BEGIN 
    EVAL Thread.Fork(NEW(Closure, id := i, apply := RApply)) 
  END MakeReaderThread;

PROCEDURE MakeForkerThread(i : CARDINAL) =
  BEGIN 
    EVAL Thread.Fork(NEW(Closure, id := i, apply := FApply)) 
  END MakeForkerThread;

PROCEDURE MakeAllocatorThread(i : CARDINAL) =
  BEGIN 
    EVAL Thread.Fork(NEW(Closure, id := i, apply := AApply)) 
  END MakeAllocatorThread;

PROCEDURE MakeCreatorThread(i : CARDINAL) =
  BEGIN 
    EVAL Thread.Fork(NEW(Closure, id := i, apply := CApply)) 
  END MakeCreatorThread;

PROCEDURE MakeLockerThread(i : CARDINAL) =
  BEGIN 
    EVAL Thread.Fork(NEW(Closure, id := i, apply := LApply)) 
  END MakeLockerThread;

TYPE 
  ThreadMaker = PROCEDURE(i : CARDINAL);
  Named = RECORD maker : ThreadMaker; named : TEXT END;

CONST
  Makers = ARRAY OF Named {
    Named { MakeReaderThread,    "read"  },
    Named { MakeForkerThread,    "fork"  },
    Named { MakeAllocatorThread, "alloc" },
    Named { MakeCreatorThread,   "creat" },
    Named { MakeLockerThread,    "lock"  } 
  };

TYPE M = [ FIRST(Makers)..LAST(Makers) ];

(**********************************************************************)

PROCEDURE RApply(cl : Closure) : REFANY =
  BEGIN
    Thread.Pause(InitPause);
    LOOP
      TRY 
        WITH rd = FileRd.Open(Filename) DO
          TRY
            LOOP
              <*UNUSED*>VAR c := Rd.GetChar(rd); BEGIN  END
            END
          EXCEPT
            Rd.EndOfFile => Rd.Close(rd)
          END;
          times1[cl.id]:= FLOOR(Time.Now()) 
        END
      EXCEPT 
        OSError.E(x) => Error("RApply: OSError.E: " & FmtAtomList(x))
      |
        Rd.Failure(x) => Error("RApply: Rd.Failure: " & FmtAtomList(x))
      END 
    END
  END RApply;

PROCEDURE FApply(cl : Closure) : REFANY =
  BEGIN
    Thread.Pause(InitPause);
    LOOP
      TRY
        WITH proc = Process.Create("sleep",
                                   ARRAY OF TEXT { "1" }) DO
          EVAL Process.Wait(proc); times1[cl.id] := FLOOR(Time.Now())
        END
      EXCEPT 
        OSError.E(x) => Error("FApply: OSError.E: " & FmtAtomList(x))
      END
    END
  END FApply;

PROCEDURE AApply(cl : Closure) : REFANY =
  BEGIN
    Thread.Pause(InitPause);
    LOOP
      VAR
        arr := NEW(REF ARRAY OF INTEGER, 1025);
      BEGIN
        FOR i := FIRST(arr^)+1 TO LAST(arr^) DO
          arr[i] := arr[i] - arr[i-1]
        END; times1[cl.id] := FLOOR(Time.Now())
      END
    END
  END AApply;

PROCEDURE CApply(cl : Closure) : REFANY =
  BEGIN
    Thread.Pause(InitPause);
    LOOP
      VAR
        t := Thread.Fork(NEW(Thread.Closure, apply := ThreadNOP));
      BEGIN
        EVAL Thread.Join(t); times1[cl.id] := FLOOR(Time.Now())
      END
    END
  END CApply;

PROCEDURE ThreadNOP(<*UNUSED*>cl : Thread.Closure) : REFANY = BEGIN RETURN NIL END ThreadNOP;

VAR mu     := NEW(MUTEX);
VAR shared := 0;

PROCEDURE LApply(cl : Closure) : REFANY =
  BEGIN
    Thread.Pause(InitPause);
    LOOP
      LOCK mu DO
        CASE cl.id MOD 2 OF
          1 => INC(shared)
        |
          0 => DEC(shared)
        ELSE
          <*ASSERT FALSE*>
        END
      END; times1[cl.id] := FLOOR(Time.Now())
    END
  END LApply;


CONST Filename = "hohum";

PROCEDURE WriteAFile() =
  <*FATAL Wr.Failure, OSError.E*>  (* errors during setup are just fatal *)
  BEGIN
    WITH wr = FileWr.Open(Filename) DO
      FOR i := 1 TO 256 DO
        FOR j := 1 TO i DO
          Wr.PutChar(wr, VAL(ORD('A') + i MOD 25, CHAR))
        END;
        Wr.PutChar(wr, '\n')
      END;
      Wr.Close(wr)
    END
  END WriteAFile;

PROCEDURE FmtStats(VAR a : ARRAY OF INTEGER) : TEXT =
  (* now is global in Main.m3 *)
  BEGIN
    IntArraySort.Sort(a);
    
    (* the result isn't quite right if NUMBER(a) is even *)
    WITH min = a[FIRST(a)],
         max = a[LAST(a)],
         med = a[LAST(a) DIV 2] DO
      RETURN Fmt.F("%s/%s/%s",Fmt.Int(now-min), Fmt.Int(now-med), Fmt.Int(now-max))
    END
  END FmtStats;

PROCEDURE FmtAtomList(err : AtomList.T) : TEXT =
  VAR
    msg := "";
    p := err;
  BEGIN
    WHILE p # NIL DO
      msg := msg & " " & Atom.ToText(p.head); p := p.tail
    END;
    RETURN msg
  END FmtAtomList;

PROCEDURE Error(msg : TEXT) =
  BEGIN
    IO.Put("ERROR " & msg & "\n")
  END Error;

PROCEDURE AddTest(test : TEXT) =
  BEGIN
    FOR i := FIRST(Makers) TO LAST(Makers) DO
      IF Text.Equal(Makers[i].named,test) THEN
        sets := sets + SET OF M { i }; RETURN
      END
    END;

    (* no match *)
    
    VAR 
      msg := "No test named \"" & test & "\", known tests:";
    BEGIN
      FOR i := FIRST(Makers) TO LAST(Makers) DO
        msg := msg & " " & Makers[i].named
      END;
      Process.Crash(msg)
    END
  END AddTest;

CONST
  DefaultNPer = 3;
VAR
  nPer := DefaultNPer; (* must be odd *)
  
  n : CARDINAL;

  times1, times2, times3 : REF ARRAY OF INTEGER;
  (* times1 : input array
     times2 : a stable copy of times1

     times3 : a copy of those bits of times1 that are active
  *)
  now : INTEGER;
  sets := SET OF M { FIRST(M) .. LAST(M) };
  
  pp := NEW(ParseParams.T).init(Stdio.stderr);

  iters := 10;
  wait  := 10;
BEGIN

  TRY
    IF pp.keywordPresent("-n")     THEN nPer := pp.getNextInt() END;
    IF pp.keywordPresent("-wait")  THEN wait := pp.getNextInt() END;
    IF pp.keywordPresent("-iters") THEN iters := pp.getNextInt() END;

    IF pp.keywordPresent("-tests") THEN 
      VAR
        s := 0;
      BEGIN
        sets := SET OF M {} ;

        WITH tests = pp.getNext(),
             l     = Text.Length(tests) DO
          FOR i := 0 TO l-1 DO
            IF i = l-1 THEN
              AddTest(Text.Sub(tests,s,l-s))
            ELSIF Text.GetChar(tests,i) = ',' THEN
              AddTest(Text.Sub(tests,s,i-s));
              s := i+1
            END
          END
        END
      END
    END

  EXCEPT
    ParseParams.Error => Process.Crash("Couldnt parse cmd-line args.")
  END;

  n := NUMBER(Makers) * nPer;
  times1 := NEW(REF ARRAY OF INTEGER, n);
  times2 := NEW(REF ARRAY OF INTEGER, n);
  times3 := NEW(REF ARRAY OF INTEGER, n);

  IO.Put("Writing file...");
  WriteAFile();
  IO.Put("done\n");

  FOR i := FIRST(M) TO LAST(M) DO
    IF i IN sets THEN
      IO.Put("Creating " & Makers[i].named & " threads...");
      FOR j := 0 TO nPer - 1 DO
        Makers[i].maker(i * nPer + j) 
      END;
      IO.Put("done\n")
    END
  END;

  IO.Put("running...printing oldest/median age/newest\n");
  FOR i := 1 TO iters DO
    FOR j := 1 TO wait DO
      Thread.Pause(1.0d0);
      IO.Put(".")
    END;
    times2^ := times1^;
    now  := FLOOR(Time.Now());
    VAR
      p := 0;
    BEGIN
      FOR i := FIRST(M) TO LAST(M) DO
        IF i IN sets THEN
          SUBARRAY(times3^,p,nPer) := SUBARRAY(times2^,i*nPer,nPer);
          INC(p,nPer)
        END
      END;
      VAR
        str := "laziest thread is " & FmtStats(SUBARRAY(times3^,0,p)) & 
                   " (tests:";
      BEGIN
        FOR i := FIRST(M) TO LAST(M) DO
          IF i IN sets THEN
            str := str & " " & Makers[i].named & " " & 
                       FmtStats(SUBARRAY(times2^,i*nPer,nPer))
          END
        END;
        str := str & ")\n";
        IO.Put(str)
      END
    END
  END
END Main.
  