# New port collection makefile for:	deepseek-harness
# Date created:				2026-10-17
# Whom:					skywalk
#
# $FreeBSD$
#

PORTNAME=	deepseek-harness
DISTVERSION=	0.2.1a4
CATEGORIES=	devel
MASTER_SITES=	https://github.com/skywalk163/deepseek-harness/releases/download/freebsd-${DISTVERSION}/ \
		https://gitcode.com/skywalk163/deepseek-harness/releases/download/freebsd-${DISTVERSION}/
DISTNAME=	${PORTNAME}-${DISTVERSION}-freebsd-amd64

MAINTAINER=	skywalk <TODO-set-your-address-before-submitting>
COMMENT=	DeepSeek open-source agent harness (CLI and web UI)
WWW=		https://github.com/deepseek-ai/deepseek-harness

LICENSE=	MIT
LICENSE_FILE=	${WRKSRC}/LICENSE

# The distfile is a prebuilt, self-contained runtime closure produced by
# tools/make-port-distfile.sh from a built checkout (see ../PORTING.md for
# the full rationale). dsh is a pnpm monorepo of ~290 workspace packages:
# its full dependency closure is not in the ports tree, and a source build
# needs 30+ minutes and 2-4 GB of RAM, which no poudriere builder accepts.
# Bundled third-party notices ship inside the distfile
# (THIRD_PARTY_NOTICES.md) and are installed with the runtime tree.
ONLY_FOR_ARCHS=		amd64
ONLY_FOR_ARCHS_REASON=	the distfile ships prebuilt native addons (node-pty, flock) for amd64; an aarch64 bundle is planned

# node24 provides the plain `node` binary on current FreeBSD.
RUN_DEPENDS=	node:www/node24 \
		bash:shells/bash \
		rg:textproc/ripgrep

USE_RC_SUBR=	dsh_web
SUB_FILES=	dsh pkg-message

# The only thing built here is the small setuid jail helper that confines
# agent commands on FreeBSD (jail(2), libjail for the jailparam API — both
# in the base system).
do-build:
	${CC} ${CFLAGS} -o ${WRKDIR}/dsh-jail-run ${WRKSRC}/freebsd/dsh-jail-run.c -ljail

do-install:
	${MKDIR} ${STAGEDIR}${PREFIX}/libexec/deepseek-harness
	cd ${WRKSRC} && ${COPYTREE_SHARE} . ${STAGEDIR}${PREFIX}/libexec/deepseek-harness
	${INSTALL_SCRIPT} ${WRKDIR}/dsh ${STAGEDIR}${PREFIX}/bin/dsh
	${INSTALL_PROGRAM} ${WRKDIR}/dsh-jail-run ${STAGEDIR}${PREFIX}/libexec/dsh-jail-run
	${CHMOD} 4755 ${STAGEDIR}${PREFIX}/libexec/dsh-jail-run

.include <bsd.port.mk>
