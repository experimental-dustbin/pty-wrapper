# pty-wrapper
Ruby PTY driver for interacting with external programs.

# Example
```ruby
p = PtyDriver.new("gnutls-cli --insecure -s -p 587 smtp.gmail.com")
# Wait until we get server status
p.wait(/gsmtp/i)
# Start the SMTP handshake process by sending HELO
p.write("HELO a\n")
# Wait until we get ack
p.wait(/at your service/i)
# Start TLS
p.write("STARTTLS\n")
# Wait until server ack
p.wait(/Ready to start TLS/i)
# Now send SIGALARM to the spawned process to get the TLS handshake started
p.signal("SIGALRM")
# Wait until we get certificate output
p.wait(/Certificate type/i)
# Send HELO again and wait for ack
p.write("HELO a\n")
p.wait(/at your service/i)
```
