PREFIX ?= /usr/local
SBINDIR ?= $(PREFIX)/sbin
MANDIR ?= $(PREFIX)/share/man/man8

SCRIPT = check_kernel.sh
MANPAGE = check_kernel.1
TARGET_MANPAGE = $(MANDIR)/check_kernel.8

.PHONY: test install uninstall

test:
	bash -n $(SCRIPT)
	@if command -v groff >/dev/null 2>&1; then groff -man -T utf8 $(MANPAGE) >/dev/null; fi
	@output=$$(bash ./$(SCRIPT) --help); \
	if printf '%s\n' "$$output" | grep -qi staging; then \
		echo "error: staging must stay hidden from help" >&2; exit 1; \
	fi

install: test
	install -D -m 0755 $(SCRIPT) $(DESTDIR)$(SBINDIR)/check_kernel
	install -D -m 0644 $(MANPAGE) $(DESTDIR)$(TARGET_MANPAGE)

uninstall:
	rm -f $(DESTDIR)$(SBINDIR)/check_kernel
	rm -f $(DESTDIR)$(TARGET_MANPAGE)
