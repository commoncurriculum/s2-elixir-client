ExUnit.start(exclude: [:proxy])

# --- Uncovered lines and why they can't be covered ---
#
# All remaining uncovered lines are exhaustive pattern match arms — defensive
# clauses that handle every possible return value from a function. They can't
# be removed (the match would be incomplete) and can't be triggered with
# available testing tools.
#
# append.ex:49,50 — decode_frame returns {:error, reason} or :incomplete
#   Requires the server to return HTTP 200 with corrupt protobuf body.
#   Toxiproxy corrupts at the TCP layer, not the HTTP/2 application layer,
#   so we can't produce a valid HTTP response with a bad protobuf payload.
#
# append_session.ex:146,149 — pre-buffered ack data in receive_ack
#   Requires the server to pipeline multiple acks into a single TCP segment
#   so data is already buffered before we call Mint.HTTP2.recv. Not triggerable
#   with s2-lite's single-ack-per-append behavior.
#
# read.ex:111 — Mint.HTTP2.cancel_request returns {:error, conn, reason}
#   cancel_request is called microseconds after receiving data on the same
#   connection. There's no window to break the socket between the successful
#   recv and the cancel call.
#
# stream_worker.ex:202 — controlling_process fails during reconnect
#   Requires Mint.HTTP2.controlling_process to fail when transferring the
#   new connection to the worker process. Would need the process to die
#   between opening the connection and transferring ownership.
#
# tail_loop.ex:57 — :end_of_stream from ReadSession.next_batch
#   s2-lite never cleanly closes read streams. The server keeps the HTTP/2
#   stream open indefinitely, so next_batch never returns :end_of_stream.
