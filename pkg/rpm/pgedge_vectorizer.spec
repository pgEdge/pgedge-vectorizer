%global pname pgedge_vectorizer
%global sname pgedge-vectorizer

%{!?llvm:%global llvm 1}

Name:		%{sname}_%{pgmajorversion}
Version:	%{pgedge_vectorizer_version}
Release:	%{pgedge_vectorizer_buildnum}%{?dist}
Summary:	A PostgreSQL extension to create chunk tables for existing text data
License:	PostgreSQL
URL:		https://github.com/pgEdge/pgedge-vectorizer
Source0:	https://github.com/pgEdge/pgedge-vectorizer/archive/refs/tags/v%{version}.tar.gz

BuildRequires:	pgedge-postgresql%{pgmajorversion}-devel libcurl-devel
Requires:	pgedge-postgresql%{pgmajorversion}-server libcurl pgedge-pgvector_%{pgmajorversion}
Provides:	%{sname}_%{pgmajorversion}

%description
A PostgreSQL extension to create chunk tables for existing text data, and populate them with embeddings using your favourite LLM.

%if %llvm
%package llvmjit
Summary:	Just-in-time compilation support for pgedge_vectorizer
Requires:	%{name}%{?_isa} = %{version}-%{release}
%if 0%{?suse_version} >= 1500
BuildRequires:	llvm17-devel clang17-devel 
Requires:	llvm17
%endif
%if 0%{?fedora} || 0%{?rhel} >= 8
BuildRequires:	llvm-devel >= 17.0 clang-devel >= 17.0
Requires:	llvm => 17.0
Provides:       %{sname}_%{pgmajorversion}-llvmjit
%endif

%description llvmjit
This package provides JIT support for pgedge_vectorizer
%endif

%prep
%setup -q -n %{sname}-%{version}

%build
USE_PGXS=1 PATH=%{pginstdir}/bin:$PATH %{__make} %{?_smp_mflags}
syft dir:%{_builddir}/%{sname}-%{version} -o cyclonedx-json > %{_builddir}/%{sname}-%{version}/%{sname}-sbom.json || exit 1

KEY_ID=$(gpg --list-secret-keys --with-colons | awk -F: '/^sec/{print $5}' | head -n 1); export KEY_ID
gpg --armor --detach-sign --output %{_builddir}/%{sname}-%{version}/%{sname}-sbom.json.asc %{_builddir}/%{sname}-%{version}/%{sname}-sbom.json || exit 1

%install
%{__rm} -rf %{buildroot}
USE_PGXS=1 PATH=%{pginstdir}/bin:$PATH %{__make} %{?_smp_mflags} install DESTDIR=%{buildroot}
mkdir -p %{buildroot}/%{pginstdir}/sbom
install -p -m 0644 %{_builddir}/%{sname}-%{version}/%{sname}-sbom.json %{buildroot}/%{pginstdir}/sbom/%{sname}-sbom.json
install -p -m 0644 %{_builddir}/%{sname}-%{version}/%{sname}-sbom.json.asc %{buildroot}/%{pginstdir}/sbom/%{sname}-sbom.json.asc

%files
%doc README.md
# LICENCE.md at the source-tree root is a symlink to docs/LICENCE.md; naming it
# here would ship the dangling symlink (docs/ is not in the payload), so point at
# the real file — %license installs by basename either way.
%license docs/LICENCE.md
%{pginstdir}/lib/%{pname}.so
%{pginstdir}/share/extension//%{pname}.control
%{pginstdir}/share/extension/%{pname}*sql
#%%dir %%{pginstdir}/include/server/extension/pgedge-vectorizer/
#%%{pginstdir}/include/server/extension/pgedge-vectorizer/*.h
%{pginstdir}/sbom/%{sname}-sbom.json
%{pginstdir}/sbom/%{sname}-sbom.json.asc

%if %llvm
%files llvmjit
   %{pginstdir}/lib/bitcode/%{pname}*.bc
   %{pginstdir}/lib/bitcode/%{pname}/src/*.bc
%endif

%changelog
* Fri Mar 13 2026 Muhammad Aqeel <muhammad.aqeel@pgedge.com> - 1.0
- Update build of pgedge_vectorizer
* Wed Jan 14 2026 Muhammad Aqeel <muhammad.aqeel@pgedge.com> - 1.0-beta2
- Update build of pgedge_vectorizer
* Mon Dec 15 2025 Muhammad Aqeel <muhammad.aqeel@pgedge.com> - 1.0-beta1
- Initial build of pgedge_vectorizer
